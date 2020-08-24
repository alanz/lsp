{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiWayIf            #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE TypeApplications #-}

{- |
This is an example language server built with haskell-lsp using a 'Reactor'
design. With a 'Reactor' all requests are handled on a /single thread/.
A thread is spun up for it, which repeatedly reads from a 'TChan' of
'ReactorInput's.
The `haskell-lsp` handlers then simply pass on all the requests and
notifications onto the channel via 'ReactorInput's.

To try out this server, install it with
> cabal install lsp-demo-reactor-server -fdemo
and plug it into your client of choice.
-}
module Main (main) where
import           Control.Concurrent
import           Control.Concurrent.STM.TChan
import qualified Control.Exception                     as E
import           Control.Lens
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import           Control.Monad.STM
import qualified Data.Aeson                            as J
import           Data.Default
import qualified Data.HashMap.Strict                   as H
import qualified Data.Text                             as T
import qualified Language.Haskell.LSP.Control          as CTRL
import qualified Language.Haskell.LSP.Core             as Core
import           Language.Haskell.LSP.Diagnostics
import qualified Language.Haskell.LSP.Types            as J
import qualified Language.Haskell.LSP.Types.Lens       as J
import qualified Language.Haskell.LSP.Utility          as U
import           Language.Haskell.LSP.VFS
import           System.Exit
import qualified System.Log.Logger                     as L


-- ---------------------------------------------------------------------
{-# ANN module ("HLint: ignore Eta reduce"         :: String) #-}
{-# ANN module ("HLint: ignore Redundant do"       :: String) #-}
{-# ANN module ("HLint: ignore Reduce duplication" :: String) #-}
-- ---------------------------------------------------------------------
--

main :: IO ()
main = do
  run (return ()) >>= \case
    0 -> exitSuccess
    c -> exitWith . ExitFailure $ c

-- ---------------------------------------------------------------------

run :: IO () -> IO Int
run dispatcherProc = flip E.catches handlers $ do

  rin  <- atomically newTChan :: IO (TChan ReactorInput)

  let
    dp lf = do
      liftIO $ U.logs "main.run:dp entered"
      _rpid  <- forkIO $ reactor lf rin
      liftIO $ U.logs "main.run:dp tchan"
      dispatcherProc
      liftIO $ U.logs "main.run:dp after dispatcherProc"
      return Nothing

    callbacks = Core.InitializeCallbacks
      { Core.onInitialConfiguration = const $ Right ()
      , Core.onConfigurationChange = const $ Right ()
      , Core.onStartup = dp
      }

  flip E.finally finalProc $ do
    Core.setupLogger Nothing [] L.DEBUG
    CTRL.run callbacks (lspHandlers rin) lspOptions

  where
    handlers = [ E.Handler ioExcept
               , E.Handler someExcept
               ]
    finalProc = L.removeAllHandlers
    ioExcept   (e :: E.IOException)       = print e >> return 1
    someExcept (e :: E.SomeException)     = print e >> return 1

-- ---------------------------------------------------------------------

syncOptions :: J.TextDocumentSyncOptions
syncOptions = J.TextDocumentSyncOptions
  { J._openClose         = Just True
  , J._change            = Just J.TdSyncIncremental
  , J._willSave          = Just False
  , J._willSaveWaitUntil = Just False
  , J._save              = Just $ J.R $ J.SaveOptions $ Just False
  }

lspOptions :: Core.Options
lspOptions = def { Core.textDocumentSync = Just syncOptions
                 , Core.executeCommandCommands = Just ["lsp-hello-command"]
                 }

-- ---------------------------------------------------------------------

-- The reactor is a process that serialises and buffers all requests from the
-- LSP client, so they can be sent to the backend compiler one at a time, and a
-- reply sent.

data ReactorInput
  = forall (m :: J.Method 'J.FromClient 'J.Request).
    ReactorInputReq (J.SMethod m) (J.RequestMessage m) (Either J.ResponseError (J.ResponseParams m) -> IO ())
  | forall (m :: J.Method 'J.FromClient 'J.Notification).
    ReactorInputNot (J.SMethod m) (J.NotificationMessage m)

-- ---------------------------------------------------------------------

-- | The monad used in the reactor
type R c a = ReaderT (Core.LspFuncs c) IO a

-- ---------------------------------------------------------------------
-- reactor monad functions
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------

reactorSendNot :: J.SServerMethod (m :: J.Method 'J.FromServer 'J.Notification)
               -> J.MessageParams m
               -> R () ()
reactorSendNot method params = do
  lf <- ask
  liftIO $ Core.sendNot lf method params

reactorSendReq :: J.SServerMethod (m :: J.Method 'J.FromServer 'J.Request)
               -> J.MessageParams m
               -> (J.LspId m -> Either J.ResponseError (J.ResponseParams m) -> R () ())
               -> R () (J.LspId m)
reactorSendReq method params responseHandler = do
  lf <- ask
  liftIO $ Core.sendReq lf method params (\lid res -> runReaderT (responseHandler lid res) lf)

-- ---------------------------------------------------------------------

publishDiagnostics :: Int -> J.NormalizedUri -> J.TextDocumentVersion -> DiagnosticsBySource -> R () ()
publishDiagnostics maxToPublish uri v diags = do
  lf <- ask
  liftIO $ Core.publishDiagnosticsFunc lf maxToPublish uri v diags

-- ---------------------------------------------------------------------

-- | Analyze the file and send any diagnostics to the client in a
-- "textDocument/publishDiagnostics" notification
sendDiagnostics :: J.NormalizedUri -> Maybe Int -> R () ()
sendDiagnostics fileUri version = do
  let
    diags = [J.Diagnostic
              (J.Range (J.Position 0 1) (J.Position 0 5))
              (Just J.DsWarning)  -- severity
              Nothing  -- code
              (Just "lsp-hello") -- source
              "Example diagnostic message"
              Nothing -- tags
              (Just (J.List []))
            ]
  -- reactorSend $ J.NotificationMessage "2.0" "textDocument/publishDiagnostics" (Just r)
  publishDiagnostics 100 fileUri version (partitionBySource diags)

-- ---------------------------------------------------------------------

-- | The single point that all events flow through, allowing management of state
-- to stitch replies and requests together from the two asynchronous sides: lsp
-- server and backend compiler
reactor :: Core.LspFuncs () -> TChan ReactorInput -> IO ()
reactor lf inp = do
  liftIO $ U.logs "reactor:entered"
  flip runReaderT lf $ forever $ do
    reactorInput <- liftIO $ atomically $ readTChan inp
    case reactorInput of
      ReactorInputReq method msg responder ->
        case handle method of
          Just f -> f msg responder
          Nothing -> pure ()
      ReactorInputNot method msg ->
        case handle method of
          Just f -> f msg
          Nothing -> pure ()

-- | Check if we have a handler, and if we create a haskell-lsp handler to pass it as
-- input into the reactor
lspHandlers :: TChan ReactorInput -> Core.Handlers
lspHandlers rin method =
  case handle method of
    Just _ -> case J.splitClientMethod method of
      J.IsClientReq -> Just $ \clientMsg responder ->
        atomically $ writeTChan rin (ReactorInputReq method clientMsg responder)
      J.IsClientNot -> Just $ \clientMsg ->
        atomically $ writeTChan rin (ReactorInputNot method clientMsg)
      J.IsClientEither -> error "TODO???"
    Nothing -> Nothing

-- | Where the actual logic resides for handling requests and notifications.
handle :: J.SMethod m -> Maybe (J.BaseHandler m (R () ()))
handle J.SInitialized = Just $ \_msg -> do
    liftIO $ U.logm "Processing the Initialized notification"
    
    -- We're initialized! Lets send a showMessageRequest now
    let params = J.ShowMessageRequestParams
                       J.MtWarning
                       "What's your favourite language extension?"
                       (Just [J.MessageActionItem "Rank2Types", J.MessageActionItem "NPlusKPatterns"])

    void $ reactorSendReq J.SWindowShowMessageRequest params $ \_lid res ->
      case res of
        Left e -> liftIO $ U.logs $ "Got an error: " ++ show e
        Right _ -> do
          reactorSendNot J.SWindowShowMessage (J.ShowMessageParams J.MtInfo "Excellent choice")

          -- We can dynamically register a capability once the user accepts it
          reactorSendNot J.SWindowShowMessage (J.ShowMessageParams J.MtInfo "Turning on code lenses dynamically")
          
          Core.LspFuncs { Core.registerCapability = registerCapability } <- ask
          let regOpts = J.CodeLensRegistrationOptions Nothing Nothing (Just False)
          
          void $ liftIO $ registerCapability J.STextDocumentCodeLens regOpts $ \_req responder -> do
            liftIO $ U.logs "Processing a textDocument/codeLens request"
            let cmd = J.Command "Say hello" "lsp-hello-command" Nothing
                rsp = J.List [J.CodeLens (J.mkRange 0 0 0 100) (Just cmd) Nothing]
            liftIO $ responder (Right rsp)

handle J.STextDocumentDidOpen = Just $ \msg -> do
  let doc  = msg ^. J.params . J.textDocument . J.uri
      fileName =  J.uriToFilePath doc
  liftIO $ U.logs $ "Processing DidOpenTextDocument for: " ++ show fileName
  sendDiagnostics (J.toNormalizedUri doc) (Just 0)

handle J.STextDocumentDidChange = Just $ \msg -> do
  let doc  = msg ^. J.params
                  . J.textDocument
                  . J.uri
                  . to J.toNormalizedUri
  liftIO $ U.logs $ "Processing DidChangeTextDocument for: " ++ show doc
  lf <- ask
  mdoc <- liftIO $ Core.getVirtualFileFunc lf doc
  case mdoc of
    Just (VirtualFile _version str _) -> do
      liftIO $ U.logs $ "Found the virtual file: " ++ show str
    Nothing -> do
      liftIO $ U.logs $ "Didn't find anything in the VFS for: " ++ show doc

handle J.STextDocumentDidSave = Just $ \msg -> do
  let doc = msg ^. J.params . J.textDocument . J.uri
      fileName = J.uriToFilePath doc
  liftIO $ U.logs $ "Processing DidSaveTextDocument  for: " ++ show fileName
  sendDiagnostics (J.toNormalizedUri doc) Nothing

handle J.STextDocumentRename = Just $ \req responder -> do
  liftIO $ U.logs "Processing a textDocument/rename request"
  let params = req ^. J.params
      J.Position l c = params ^. J.position
      newName = params ^. J.newName
  lf <- ask
  vdoc <- liftIO $ Core.getVersionedTextDocFunc lf (params ^. J.textDocument)
  -- Replace some text at the position with what the user entered
  let edit = J.TextEdit (J.mkRange l c l (c + T.length newName)) newName
      tde = J.TextDocumentEdit vdoc (J.List [edit])
      -- "documentChanges" field is preferred over "changes"
      rsp = J.WorkspaceEdit Nothing (Just (J.List [tde]))
  liftIO $ responder (Right rsp)

handle J.STextDocumentHover = Just $ \req responder -> do
  liftIO $ U.logs "Processing a textDocument/hover request"
  let J.HoverParams _doc pos _workDone = req ^. J.params
      J.Position _l _c' = pos
      rsp = J.Hover ms (Just range)
      ms = J.HoverContents $ J.markedUpContent "lsp-hello" "Your type info here!"
      range = J.Range pos pos
  liftIO $ responder (Right rsp)

handle J.STextDocumentCodeAction = Just $ \req responder -> do
  liftIO $ U.logs $ "Processing a textDocument/codeAction request"
  let params = req ^. J.params
      doc = params ^. J.textDocument
      (J.List diags) = params ^. J.context . J.diagnostics
      -- makeCommand only generates commands for diagnostics whose source is us
      makeCommand (J.Diagnostic (J.Range start _) _s _c (Just "lsp-hello") _m _t _l) = [J.Command title cmd cmdparams]
        where
          title = "Apply LSP hello command:" <> head (T.lines _m)
          -- NOTE: the cmd needs to be registered via the InitializeResponse message. See lspOptions above
          cmd = "lsp-hello-command"
          -- need 'file' and 'start_pos'
          args = J.List
                  [ J.Object $ H.fromList [("file",     J.Object $ H.fromList [("textDocument",J.toJSON doc)])]
                  , J.Object $ H.fromList [("start_pos",J.Object $ H.fromList [("position",    J.toJSON start)])]
                  ]
          cmdparams = Just args
      makeCommand (J.Diagnostic _r _s _c _source _m _t _l) = []
      rsp = J.List $ map J.L $ concatMap makeCommand diags
  liftIO $ responder (Right rsp)

handle J.SWorkspaceExecuteCommand = Just $ \req responder -> do
  liftIO $ U.logs "Processing a workspace/executeCommand request"
  let params = req ^. J.params
      margs = params ^. J.arguments

  liftIO $ U.logs $ "The arguments are: " ++ show margs
  liftIO $ responder (Right (J.Object mempty)) -- respond to the request

  reactorSendNot J.SWindowShowMessage
                 (J.ShowMessageParams J.MtInfo "I was told to execute a command")


handle _ = Nothing

-- ---------------------------------------------------------------------