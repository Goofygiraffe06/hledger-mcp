{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main (main) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (filterM, forM, unless, when)
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Char (isDigit)
import Data.Foldable (traverse_)
import Data.List (sort)
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (getZonedTime, localDay, zonedTimeToLocalTime)
import Hledger.Data.Amount (showMixedAmountOneLine)
import Hledger.Data.Journal
import Hledger.Data.Transaction (showTransaction)
import Hledger.Data.Types
import Hledger.Query
import Hledger.Read.Common (Reader (rReadFn), definputopts)
import Hledger.Read.JournalReader qualified as JournalReader
import Hledger.Reports.BalanceReport
import Hledger.Reports.PostingsReport
import Hledger.Reports.ReportOptions (ReportSpec (..), defreportspec)
import System.Directory
import System.Environment (getArgs, lookupEnv)
import System.FilePath ((</>), takeDirectory, takeFileName)
import System.IO

serverName, serverVersion, modernProtocol :: Text
serverName = "hledger-mcp"
serverVersion = "0.1.1"
modernProtocol = "2026-07-28"

journalReader :: Reader IO
journalReader = JournalReader.reader

data Workspace = Workspace
  { rootPath :: FilePath
  , mainJournal :: FilePath
  , accountsJournal :: Maybe FilePath
  , openingJournal :: Maybe FilePath
  , transactionsPath :: Maybe FilePath
  }

data Command = Serve | Init | ShowPaths | ShowVersion | ShowHelp
  deriving (Eq)

data CliOptions = CliOptions
  { command :: Command
  , homeOverride :: Maybe FilePath
  , journalOverride :: Maybe FilePath
  }

data RpcRequest = RpcRequest
  { requestId :: Maybe Value
  , requestMethod :: Text
  , requestParams :: Value
  }

instance FromJSON RpcRequest where
  parseJSON = withObject "JSON-RPC request" $ \o ->
    RpcRequest <$> o .:? "id" <*> o .: "method" <*> o .:? "params" .!= object []

data PostingInput = PostingInput
  { account :: Text
  , amount :: Maybe Text
  , comment :: Maybe Text
  }

instance FromJSON PostingInput where
  parseJSON = withObject "posting" $ \o ->
    PostingInput <$> o .: "account" <*> o .:? "amount" <*> o .:? "comment"

data TransactionInput = TransactionInput
  { date :: Text
  , description :: Text
  , status :: Maybe Text
  , code :: Maybe Text
  , txComment :: Maybe Text
  , postings :: [PostingInput]
  , commit :: Bool
  }

instance FromJSON TransactionInput where
  parseJSON = withObject "transaction" $ \o ->
    TransactionInput
      <$> o .: "date"
      <*> o .: "description"
      <*> o .:? "status"
      <*> o .:? "code"
      <*> o .:? "comment"
      <*> o .: "postings"
      <*> o .:? "commit" .!= False

data AccountInput = AccountInput
  { accountName :: Text
  , accountType :: Maybe Text
  , accountComment :: Maybe Text
  , accountCommit :: Bool
  }

instance FromJSON AccountInput where
  parseJSON = withObject "account declaration" $ \o ->
    AccountInput
      <$> o .: "account"
      <*> o .:? "type"
      <*> o .:? "comment"
      <*> o .:? "commit" .!= False

data JournalTextInput = JournalTextInput
  { destination :: Text
  , journalText :: Text
  , destinationYear :: Maybe Text
  , textCommit :: Bool
  }

instance FromJSON JournalTextInput where
  parseJSON = withObject "journal text" $ \o ->
    JournalTextInput
      <$> o .: "destination"
      <*> o .: "text"
      <*> o .:? "year"
      <*> o .:? "commit" .!= False

main :: IO ()
main = do
  hSetBuffering stdin LineBuffering
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  getArgs >>= \args -> case parseOptions args of
    Left err -> TIO.hPutStrLn stderr err >> TIO.hPutStrLn stderr helpText >> fail "invalid arguments"
    Right options -> do
      workspace <- resolveWorkspace options
      case options.command of
        Serve -> loop workspace
        Init -> setupWorkspace workspace >>= \case
          Left err -> fail err
          Right created -> emit $ object
            [ "root" .= workspace.rootPath
            , "mainJournal" .= workspace.mainJournal
            , "created" .= created
            ]
        ShowPaths -> emit $ object
          [ "root" .= workspace.rootPath
          , "mainJournal" .= workspace.mainJournal
          , "accountsJournal" .= workspace.accountsJournal
          , "openingJournal" .= workspace.openingJournal
          , "transactionsPath" .= workspace.transactionsPath
          ]
        ShowVersion -> TIO.putStrLn $ serverName <> " " <> serverVersion
        ShowHelp -> TIO.putStrLn helpText

parseOptions :: [String] -> Either Text CliOptions
parseOptions = go $ CliOptions Serve Nothing Nothing
  where
    go options [] = Right options
    go options ("--init":rest) = go options{command=Init} rest
    go options ("--show-paths":rest) = go options{command=ShowPaths} rest
    go options ("--version":rest) = go options{command=ShowVersion} rest
    go options ("--help":rest) = go options{command=ShowHelp} rest
    go options ("-h":rest) = go options{command=ShowHelp} rest
    go options ("--home":path:rest) = go options{homeOverride=Just path} rest
    go options ("--journal":path:rest) = go options{journalOverride=Just path} rest
    go _ ["--home"] = Left "--home requires a directory"
    go _ ["--journal"] = Left "--journal requires a file"
    go _ (unknown:_) = Left $ "unknown argument: " <> T.pack unknown

helpText :: Text
helpText = T.unlines
  [ "hledger-mcp - agent-native plain-text accounting"
  , ""
  , "Usage: hledger-mcp [--home DIR | --journal FILE] [COMMAND]"
  , ""
  , "Commands:"
  , "  --init        Create the workspace without overwriting files"
  , "  --show-paths  Print resolved workspace paths as JSON"
  , "  --version     Print the version"
  , "  --help        Show this help"
  , ""
  , "With no command, run the MCP stdio server. HLEDGER_MCP_HOME and"
  , "HLEDGER_FILE provide environment-variable equivalents."
  ]

resolveWorkspace :: CliOptions -> IO Workspace
resolveWorkspace options = case options.journalOverride of
  Just path -> pure $ legacyWorkspace path
  Nothing -> case options.homeOverride of
    Just root -> pure $ managedWorkspace root
    Nothing -> resolveEnvironment
  where
    resolveEnvironment = lookupEnv "HLEDGER_FILE" >>= \case
      Just path | not (null path) -> pure $ legacyWorkspace path
      _ -> do
        configuredRoot <- lookupEnv "HLEDGER_MCP_HOME"
        root <- case configuredRoot of
          Just path | not (null path) -> pure path
          _ -> getXdgDirectory XdgData ("hledger-mcp" </> "personal")
        pure $ managedWorkspace root

legacyWorkspace :: FilePath -> Workspace
legacyWorkspace path = Workspace
    { rootPath = normalDirectory path
    , mainJournal = path
    , accountsJournal = Nothing
    , openingJournal = Nothing
    , transactionsPath = Nothing
    }

managedWorkspace :: FilePath -> Workspace
managedWorkspace root = Workspace
  { rootPath = root
  , mainJournal = root </> "main.journal"
  , accountsJournal = Just $ root </> "accounts.journal"
  , openingJournal = Just $ root </> "opening-balances.journal"
  , transactionsPath = Just $ root </> "transactions"
  }

loop :: Workspace -> IO ()
loop workspace = do
  eof <- hIsEOF stdin
  unless eof $ do
    line <- BS.hGetLine stdin
    case eitherDecodeStrict line of
      Left err -> emit $ rpcError Null (-32700) "Parse error" (Just $ String $ T.pack err)
      Right request -> handleRequest workspace request >>= mapM_ emit
    loop workspace

emit :: Value -> IO ()
emit payload = BL.putStrLn (encode payload) >> hFlush stdout

handleRequest :: Workspace -> RpcRequest -> IO (Maybe Value)
handleRequest workspace RpcRequest{..}
  | requestMethod == "notifications/initialized" = pure Nothing
  | requestMethod == "notifications/cancelled" = pure Nothing
  | requestMethod == "ping" = reply $ object []
  | requestMethod == "initialize" = reply $ legacyInitialize requestParams
  | requestMethod == "server/discover" = reply modernDiscovery
  | requestMethod == "tools/list" = reply modernToolList
  | requestMethod == "tools/call" = do
      result <- callTool workspace requestParams
      reply result
  | otherwise = pure $ Just $ rpcError (fromMaybe Null requestId) (-32601) "Method not found" Nothing
  where
    reply result = pure $ (\rid -> rpcResult rid result) <$> requestId

legacyInitialize :: Value -> Value
legacyInitialize params = object
  [ "protocolVersion" .= requestedVersion
  , "capabilities" .= object ["tools" .= object ["listChanged" .= False]]
  , "serverInfo" .= object ["name" .= serverName, "version" .= serverVersion]
  , "instructions" .= instructions
  ]
  where
    requestedVersion = fromMaybe ("2025-06-18" :: Text) $ lookupText "protocolVersion" params

modernDiscovery :: Value
modernDiscovery = object
  [ "resultType" .= String "complete"
  , "supportedVersions" .= [modernProtocol]
  , "capabilities" .= object ["tools" .= object ["listChanged" .= False]]
  , "instructions" .= instructions
  , "ttlMs" .= (3600000 :: Int)
  , "cacheScope" .= String "private"
  , "_meta" .= object
      [ "io.modelcontextprotocol/serverInfo" .= object
          [ "name" .= serverName, "version" .= serverVersion ]
      ]
  ]

instructions :: Text
instructions = T.unlines
  [ "Use this server for personal double-entry accounting in an hledger workspace."
  , "Call setup_workspace when the workspace is new; it creates included accounts, opening balances, and yearly transaction files."
  , "Translate the user's plain-language statement into a record_transaction call."
  , "Always preview with commit=false first. Commit only when the user has asked to record it."
  , "Use declare_account for explicit chart-of-accounts declarations."
  , "Never invent an account or amount when the intent is ambiguous; inspect list_accounts first."
  , "Amounts use hledger syntax, for example INR 450, $12.50, or -2 BTC."
  ]

modernToolList :: Value
modernToolList = object
  [ "resultType" .= String "complete"
  , "tools" .= toolDefinitions
  , "ttlMs" .= (3600000 :: Int)
  , "cacheScope" .= String "private"
  ]

toolDefinitions :: [Value]
toolDefinitions =
  [ tool "setup_workspace" "Create the portable multi-file accounting workspace without overwriting existing files." emptySchema False
  , tool "journal_info" "Summarise the configured workspace and journal, including files, accounts, commodities, transaction count and date range." emptySchema True
  , tool "list_accounts" "List declared and used accounts. Call this before choosing accounts for a new transaction." emptySchema True
  , tool "declare_account" "Preview or add an account directive to accounts.journal, with an optional hledger account type." accountSchema False
  , tool "append_journal_text" "Advanced: preview or append validated hledger directives for commodities, payees, prices, tags, periodic rules, or other native syntax. Include directives are rejected." journalTextSchema False
  , tool "balance" "Return account balances. The optional query uses hledger query syntax, such as 'expenses date:thismonth'." querySchema True
  , tool "register" "Return matching postings with running totals. The optional query uses hledger query syntax." registerSchema True
  , tool "validate_journal" "Parse and fully validate the configured journal without changing it." emptySchema True
  , tool "record_transaction" "Preview or append one validated double-entry transaction. The model translates the user's plain sentence into these fields. Defaults to preview; set commit=true only when a write is intended." transactionSchema False
  ]

tool :: Text -> Text -> Value -> Bool -> Value
tool name description schema readOnly = object
  [ "name" .= name
  , "description" .= description
  , "inputSchema" .= schema
  , "annotations" .= object
      [ "readOnlyHint" .= readOnly
      , "destructiveHint" .= False
      , "idempotentHint" .= readOnly
      , "openWorldHint" .= False
      ]
  ]

emptySchema, querySchema, registerSchema, accountSchema, journalTextSchema, transactionSchema :: Value
emptySchema = object ["type" .= String "object", "additionalProperties" .= False]
querySchema = object
  [ "type" .= String "object"
  , "properties" .= object ["query" .= stringProperty "Optional hledger query"]
  , "additionalProperties" .= False
  ]
registerSchema = object
  [ "type" .= String "object"
  , "properties" .= object
      [ "query" .= stringProperty "Optional hledger query"
      , "limit" .= object ["type" .= String "integer", "minimum" .= (1 :: Int), "maximum" .= (1000 :: Int), "default" .= (100 :: Int)]
      ]
  , "additionalProperties" .= False
  ]
accountSchema = object
  [ "type" .= String "object"
  , "properties" .= object
      [ "account" .= stringProperty "Full hledger account name"
      , "type" .= object
          [ "type" .= String "string"
          , "enum" .= (["asset", "liability", "equity", "revenue", "expense", "cash", "conversion"] :: [Text])
          ]
      , "comment" .= stringProperty "Optional human-readable account note"
      , "commit" .= object ["type" .= String "boolean", "default" .= False]
      ]
  , "required" .= (["account"] :: [Text])
  , "additionalProperties" .= False
  ]
journalTextSchema = object
  [ "type" .= String "object"
  , "properties" .= object
      [ "destination" .= object
          [ "type" .= String "string"
          , "enum" .= (["main", "accounts", "opening", "transactions"] :: [Text])
          ]
      , "text" .= stringProperty "Native hledger journal text to validate and append"
      , "year" .= stringProperty "Four-digit year, required for the transactions destination"
      , "commit" .= object ["type" .= String "boolean", "default" .= False]
      ]
  , "required" .= (["destination", "text"] :: [Text])
  , "additionalProperties" .= False
  ]
transactionSchema = object
  [ "type" .= String "object"
  , "properties" .= object
      [ "date" .= stringProperty "ISO date, YYYY-MM-DD"
      , "description" .= stringProperty "Payee and/or transaction description"
      , "status" .= object ["type" .= String "string", "enum" .= (["cleared", "pending", "unmarked"] :: [Text])]
      , "code" .= stringProperty "Optional reference or invoice code"
      , "comment" .= stringProperty "Optional transaction comment"
      , "postings" .= object
          [ "type" .= String "array"
          , "minItems" .= (2 :: Int)
          , "items" .= object
              [ "type" .= String "object"
              , "properties" .= object
                  [ "account" .= stringProperty "Full hledger account name"
                  , "amount" .= stringProperty "hledger amount; omit on at most one posting so hledger infers the balancing amount"
                  , "comment" .= stringProperty "Optional posting comment"
                  ]
              , "required" .= (["account"] :: [Text])
              , "additionalProperties" .= False
              ]
          ]
      , "commit" .= object ["type" .= String "boolean", "default" .= False, "description" .= String "False previews; true appends after validation"]
      ]
  , "required" .= (["date", "description", "postings"] :: [Text])
  , "additionalProperties" .= False
  ]

stringProperty :: Text -> Value
stringProperty description = object ["type" .= String "string", "description" .= description]

callTool :: Workspace -> Value -> IO Value
callTool workspace params = case params of
  Object o -> case KM.lookup "name" o of
    Just (String name) -> dispatch name (fromMaybe (object []) $ KM.lookup "arguments" o)
    _ -> pure $ toolError "tools/call requires a string name"
  _ -> pure $ toolError "tools/call params must be an object"
  where
    dispatch "setup_workspace" _ = setupWorkspace workspace >>= \case
      Left err -> pure $ toolError $ T.pack err
      Right created -> pure $ toolSuccess $ object
        [ "root" .= workspace.rootPath
        , "mainJournal" .= workspace.mainJournal
        , "created" .= created
        ]
    dispatch "journal_info" _ = withJournal workspace.mainJournal $ journalInfo workspace
    dispatch "list_accounts" _ = withJournal workspace.mainJournal $ \j ->
      pure $ toolSuccess $ object ["accounts" .= sort (journalAccountNamesDeclaredOrUsed j)]
    dispatch "declare_account" args = declareAccount workspace args
    dispatch "append_journal_text" args = appendJournalText workspace args
    dispatch "balance" args = withJournal workspace.mainJournal $ balanceTool args
    dispatch "register" args = withJournal workspace.mainJournal $ registerTool args
    dispatch "validate_journal" _ = withJournal workspace.mainJournal $ \j ->
      pure $ toolSuccess $ object
        [ "valid" .= True
        , "transactions" .= length (jtxns j)
        , "postings" .= length (journalPostings j)
        ]
    dispatch "record_transaction" args = recordTransaction workspace args
    dispatch unknown _ = pure $ toolError $ "Unknown tool: " <> unknown

withJournal :: FilePath -> (Journal -> IO Value) -> IO Value
withJournal path action = loadJournal path >>= \case
  Left err -> pure $ toolError $ T.pack err
  Right journal -> action journal

loadJournal :: FilePath -> IO (Either String Journal)
loadJournal path = do
  exists <- doesFileExist path
  if exists
    then withFile path ReadMode $ \handle ->
      runExceptT $ rReadFn journalReader definputopts path handle
    else pure $ Right nulljournal

journalInfo :: Workspace -> Journal -> IO Value
journalInfo workspace journal = do
  files <- workspaceFiles workspace
  pure $ toolSuccess $ object
    [ "root" .= workspace.rootPath
    , "mainJournal" .= workspace.mainJournal
    , "files" .= files
    , "transactions" .= length (jtxns journal)
    , "postings" .= length (journalPostings journal)
    , "accounts" .= sort (journalAccountNamesDeclaredOrUsed journal)
    , "commodities" .= Set.toList (journalCommodities journal)
    , "dateRange" .= show (journalDateSpan False journal)
    ]

workspaceFiles :: Workspace -> IO [FilePath]
workspaceFiles workspace = do
  let fixed = workspace.mainJournal : foldMap pure workspace.accountsJournal <> foldMap pure workspace.openingJournal
  transactionFiles <- case workspace.transactionsPath of
    Nothing -> pure []
    Just directory -> do
      exists <- doesDirectoryExist directory
      if exists
        then map (directory </>) . sort <$> listDirectory directory
        else pure []
  filterM doesFileExist (fixed <> transactionFiles)

balanceTool :: Value -> Journal -> IO Value
balanceTool args journal = parseToolQuery args >>= \case
  Left err -> pure $ toolError err
  Right query -> do
    let spec = defreportspec {_rsQuery = query}
        (rows, total) = balanceReport spec journal
        rowValue (fullName, displayName, indent, balanceValue) = object
          [ "account" .= fullName
          , "displayName" .= displayName
          , "indent" .= indent
          , "balance" .= showMixedAmountOneLine balanceValue
          ]
    pure $ toolSuccess $ object
      [ "rows" .= map rowValue rows
      , "total" .= showMixedAmountOneLine total
      ]

registerTool :: Value -> Journal -> IO Value
registerTool args journal = parseToolQuery args >>= \case
  Left err -> pure $ toolError err
  Right query -> do
    let limit = max 1 . min 1000 $ fromMaybe 100 (lookupInt "limit" args)
        spec = defreportspec {_rsQuery = query}
        rows = take limit $ postingsReport spec journal
        rowValue (mdate, _, mdescription, postingRow, running) = object
          [ "date" .= fmap show mdate
          , "description" .= mdescription
          , "account" .= paccount postingRow
          , "amount" .= showMixedAmountOneLine (pamount postingRow)
          , "runningTotal" .= showMixedAmountOneLine running
          ]
    pure $ toolSuccess $ object ["rows" .= map rowValue rows, "limit" .= limit]

parseToolQuery :: Value -> IO (Either Text Query)
parseToolQuery args = do
  today <- localDay . zonedTimeToLocalTime <$> getZonedTime
  pure $ case lookupText "query" args of
    Nothing -> Right Any
    Just queryText -> case parseQuery today queryText of
      Left err -> Left $ T.pack err
      Right (query, _) -> Right query

recordTransaction :: Workspace -> Value -> IO Value
recordTransaction workspace args = case fromJSON args of
  Error err -> pure $ toolError $ T.pack err
  Success input -> case renderInput input of
    Left err -> pure $ toolError err
    Right draft -> validateEntry draft >>= \case
      Left err -> pure $ toolError $ T.pack err
      Right canonical -> case transactionTarget workspace input.date of
        Left err -> pure $ toolError err
        Right target -> if input.commit
          then commitWorkspaceFragment workspace target canonical >>= \case
            Left err -> pure $ toolError $ T.pack err
            Right () -> pure $ toolSuccess $ object
              [ "committed" .= True
              , "journal" .= workspace.mainJournal
              , "file" .= target
              , "entry" .= canonical
              ]
          else validateWorkspacePreview workspace canonical >>= \case
            Left err -> pure $ toolError $ T.pack err
            Right () -> pure $ toolSuccess $ object
              [ "committed" .= False
              , "valid" .= True
              , "file" .= target
              , "entry" .= canonical
              ]

declareAccount :: Workspace -> Value -> IO Value
declareAccount workspace args = case fromJSON args of
  Error err -> pure $ toolError $ T.pack err
  Success input -> case renderAccount input of
    Left err -> pure $ toolError err
    Right declaration -> do
      let target = fromMaybe workspace.mainJournal workspace.accountsJournal
      if input.accountCommit
        then commitWorkspaceFragment workspace target declaration >>= \case
          Left err -> pure $ toolError $ T.pack err
          Right () -> pure $ toolSuccess $ object
            [ "committed" .= True, "file" .= target, "declaration" .= declaration ]
        else validateWorkspacePreview workspace declaration >>= \case
          Left err -> pure $ toolError $ T.pack err
          Right () -> pure $ toolSuccess $ object
            [ "committed" .= False, "valid" .= True, "file" .= target, "declaration" .= declaration ]

appendJournalText :: Workspace -> Value -> IO Value
appendJournalText workspace args = case fromJSON args of
  Error err -> pure $ toolError $ T.pack err
  Success input -> case journalTextTarget workspace input of
    Left err -> pure $ toolError err
    Right target -> case normaliseJournalFragment input.journalText of
      Left err -> pure $ toolError err
      Right fragment -> if input.textCommit
        then commitWorkspaceFragment workspace target fragment >>= \case
          Left err -> pure $ toolError $ T.pack err
          Right () -> pure $ toolSuccess $ object
            [ "committed" .= True, "file" .= target, "text" .= fragment ]
        else validateWorkspacePreview workspace fragment >>= \case
          Left err -> pure $ toolError $ T.pack err
          Right () -> pure $ toolSuccess $ object
            [ "committed" .= False, "valid" .= True, "file" .= target, "text" .= fragment ]

journalTextTarget :: Workspace -> JournalTextInput -> Either Text FilePath
journalTextTarget workspace input = case input.destination of
  "main" -> Right workspace.mainJournal
  "accounts" -> maybe (Right workspace.mainJournal) Right workspace.accountsJournal
  "opening" -> maybe (Right workspace.mainJournal) Right workspace.openingJournal
  "transactions" -> case (workspace.transactionsPath, input.destinationYear) of
    (Nothing, _) -> Right workspace.mainJournal
    (Just directory, Just year) | validYear year -> Right $ directory </> T.unpack year <> ".journal"
    (Just _, _) -> Left "transactions destination requires a four-digit year"
  other -> Left $ "unsupported destination: " <> other
  where
    validYear year = T.length year == 4 && T.all isDigit year

normaliseJournalFragment :: Text -> Either Text Text
normaliseJournalFragment raw = do
  when (T.null $ T.strip raw) $ Left "journal text must not be empty"
  let significantLines = map (T.toLower . T.stripStart) $ T.lines raw
  when (any ("include " `T.isPrefixOf`) significantLines) $
    Left "include directives are managed by the workspace and cannot be appended through this tool"
  pure $ T.stripEnd raw <> "\n\n"

renderAccount :: AccountInput -> Either Text Text
renderAccount AccountInput{..} = do
  rejectLineBreak "account" accountName
  when (T.null $ T.strip accountName) $ Left "account must not be empty"
  traverse_ (rejectLineBreak "account comment") accountComment
  typeCode <- traverse accountTypeCode accountType
  let note = maybe [] (\value -> ["; " <> value]) accountComment
      suffix = maybe "" ("  ; type: " <>) typeCode
  pure $ T.unlines $ note <> ["account " <> T.strip accountName <> suffix, ""]

accountTypeCode :: Text -> Either Text Text
accountTypeCode = \case
  "asset" -> Right "A"
  "liability" -> Right "L"
  "equity" -> Right "E"
  "revenue" -> Right "R"
  "expense" -> Right "X"
  "cash" -> Right "C"
  "conversion" -> Right "V"
  other -> Left $ "unsupported account type: " <> other

transactionTarget :: Workspace -> Text -> Either Text FilePath
transactionTarget workspace dateText = case workspace.transactionsPath of
  Nothing -> Right workspace.mainJournal
  Just directory ->
    let year = T.take 4 dateText
    in if T.length year == 4 && T.all isDigit year
      then Right $ directory </> T.unpack year <> ".journal"
      else Left "date must start with a four-digit year"

renderInput :: TransactionInput -> Either Text Text
renderInput TransactionInput{..} = do
  rejectLineBreak "date" date
  rejectLineBreak "description" description
  when (T.null $ T.strip description) $ Left "description must not be empty"
  when (length postings < 2) $ Left "a transaction needs at least two postings"
  when (length (filter ((== Nothing) . (.amount)) postings) > 1) $
    Left "at most one posting may omit amount"
  marker <- case fromMaybe "unmarked" status of
    "cleared" -> Right " *"
    "pending" -> Right " !"
    "unmarked" -> Right ""
    other -> Left $ "unsupported status: " <> other
  renderedPostings <- forM postings $ \postingInput -> do
    rejectLineBreak "account" postingInput.account
    when (T.null $ T.strip postingInput.account) $ Left "account must not be empty"
    traverse_ (rejectLineBreak "amount") postingInput.amount
    traverse_ (rejectLineBreak "posting comment") postingInput.comment
    let amountText = maybe "" ("  " <>) postingInput.amount
        commentText = maybe "" ("  ; " <>) postingInput.comment
    pure $ "    " <> postingInput.account <> amountText <> commentText
  traverse_ (rejectLineBreak "code") code
  traverse_ (rejectLineBreak "comment") txComment
  let codeText = maybe "" (\codeValue -> " (" <> codeValue <> ")") code
      commentText = maybe "" ("  ; " <>) txComment
      header = date <> marker <> codeText <> " " <> T.strip description <> commentText
  pure $ T.unlines (header : renderedPostings) <> "\n"

rejectLineBreak :: Text -> Text -> Either Text ()
rejectLineBreak field fieldValue = when (T.any (`elem` ['\n', '\r']) fieldValue) $
  Left $ field <> " must be one line"

setupWorkspace :: Workspace -> IO (Either String [FilePath])
setupWorkspace workspace = withWorkspaceLock workspace $ setupWorkspaceUnlocked workspace

setupWorkspaceUnlocked :: Workspace -> IO (Either String [FilePath])
setupWorkspaceUnlocked workspace = do
  createDirectoryIfMissing True workspace.rootPath
  case (workspace.accountsJournal, workspace.openingJournal, workspace.transactionsPath) of
    (Just accountsPath, Just openingPath, Just transactionsDirectory) -> do
      createDirectoryIfMissing True transactionsDirectory
      today <- localDay . zonedTimeToLocalTime <$> getZonedTime
      let yearPath = transactionsDirectory </> take 4 (show today) <> ".journal"
      created <- fmap concat $ sequence
        [ writeIfMissing workspace.mainJournal mainJournalTemplate
        , writeIfMissing accountsPath accountsTemplate
        , writeIfMissing openingPath openingTemplate
        , writeIfMissing yearPath "; Transactions for this year. Managed by hledger-mcp.\n"
        ]
      pure $ Right created
    _ -> Right <$> writeIfMissing workspace.mainJournal ""

mainJournalTemplate :: Text
mainJournalTemplate = T.unlines
  [ "; hledger-mcp personal accounting workspace"
  , "; This is the root journal. Keep records in the included files."
  , "include accounts.journal"
  , "include opening-balances.journal"
  , "include transactions/*.journal"
  , ""
  ]

accountsTemplate :: Text
accountsTemplate = T.unlines
  [ "; Chart of accounts. Agents add explicit account directives here."
  , "; Example: account assets:bank:checking  ; type: A"
  , ""
  ]

openingTemplate :: Text
openingTemplate = T.unlines
  [ "; Opening balances and migration entries belong here."
  , ""
  ]

writeIfMissing :: FilePath -> Text -> IO [FilePath]
writeIfMissing path content = do
  exists <- doesFileExist path
  if exists
    then pure []
    else do
      createDirectoryIfMissing True (normalDirectory path)
      TIO.writeFile path content
      pure [path]

withWorkspaceLock :: Workspace -> IO (Either String a) -> IO (Either String a)
withWorkspaceLock workspace action = do
  let lockPath = workspace.rootPath </> ".hledger-mcp.lock"
  createDirectoryIfMissing True workspace.rootPath
  locked <- try @IOException $
    bracket
      (createDirectory lockPath)
      (const $ removeDirectory lockPath)
      (const action)
  pure $ either (Left . ("could not acquire workspace lock: " <>) . show) id locked

validateEntry :: Text -> IO (Either String Text)
validateEntry draft = withTempJournal "." draft $ \path handle -> do
  hSeek handle AbsoluteSeek 0
  runExceptT (rReadFn journalReader definputopts path handle) >>= \case
    Left err -> pure $ Left err
    Right journal -> case jtxns journal of
      [txn] -> pure $ Right $ showTransaction txn
      _ -> pure $ Left "expected exactly one transaction"

validateCombined :: FilePath -> Text -> IO (Either String ())
validateCombined path entry = do
  exists <- doesFileExist path
  current <- if exists then TIO.readFile path else pure ""
  let directory = normalDirectory path
  createDirectoryIfMissing True directory
  withTempJournal directory (current <> separator current <> entry) $ \tempPath handle -> do
    hClose handle
    withFile tempPath ReadMode (runExceptT . rReadFn journalReader definputopts tempPath)
      >>= pure . fmap (const ())
  where
    separator text | T.null text || T.isSuffixOf "\n\n" text = ""
                   | T.isSuffixOf "\n" text = "\n"
                   | otherwise = "\n\n"

validateWorkspacePreview :: Workspace -> Text -> IO (Either String ())
validateWorkspacePreview workspace fragment = do
  exists <- doesFileExist workspace.mainJournal
  if exists
    then validateCombinedWorkspace workspace fragment
    else validateText fragment

validateText :: Text -> IO (Either String ())
validateText content = withTempJournal "." content $ \path handle -> do
  hSeek handle AbsoluteSeek 0
  runExceptT (rReadFn journalReader definputopts path handle) >>= pure . fmap (const ())

validateCombinedWorkspace :: Workspace -> Text -> IO (Either String ())
validateCombinedWorkspace workspace fragment = case workspace.transactionsPath of
  Nothing -> validateCombined workspace.mainJournal fragment
  Just _ -> do
    rootContents <- TIO.readFile workspace.mainJournal
    withTempJournal workspace.rootPath fragment $ \candidatePath candidateHandle -> do
      hClose candidateHandle
      let candidateInclude = "\ninclude " <> T.pack (takeFileName candidatePath) <> "\n"
      withTempJournal workspace.rootPath (rootContents <> candidateInclude) $ \tempMain tempHandle -> do
        hClose tempHandle
        withFile tempMain ReadMode (runExceptT . rReadFn journalReader definputopts tempMain)
          >>= pure . fmap (const ())

appendEntry :: FilePath -> Text -> IO (Either String ())
appendEntry path entry = do
  let directory = normalDirectory path
  createDirectoryIfMissing True directory
  exists <- doesFileExist path
  needsGap <- if exists then do
    content <- TIO.readFile path
    pure $ not (T.null content) && not (T.isSuffixOf "\n\n" content)
    else pure False
  result <- try @IOException $ withFile path AppendMode $ \handle -> do
    when needsGap $ TIO.hPutStr handle "\n"
    TIO.hPutStr handle entry
    hFlush handle
  pure $ either (Left . show) Right result

commitWorkspaceFragment :: Workspace -> FilePath -> Text -> IO (Either String ())
commitWorkspaceFragment workspace target fragment = withWorkspaceLock workspace $ do
  setupWorkspaceUnlocked workspace >>= \case
    Left err -> pure $ Left err
    Right _ -> validateCombinedWorkspace workspace fragment >>= \case
      Left err -> pure $ Left err
      Right () -> appendEntry target fragment

withTempJournal :: FilePath -> Text -> (FilePath -> Handle -> IO a) -> IO a
withTempJournal directory content action =
  bracket
    (openTempFile directory ".hledger-mcp.tmp")
    (\(path, handle) -> do
      _ <- try @IOException $ hClose handle
      _ <- try @IOException $ removeFile path
      pure ())
    (\(path, handle) -> TIO.hPutStr handle content >> hFlush handle >> action path handle)

normalDirectory :: FilePath -> FilePath
normalDirectory path = case takeDirectory path of
  "" -> "."
  directory -> directory

toolSuccess :: Value -> Value
toolSuccess payload = object
  [ "resultType" .= String "complete"
  , "content" .= [object ["type" .= String "text", "text" .= compactText payload]]
  , "structuredContent" .= payload
  , "isError" .= False
  ]

toolError :: Text -> Value
toolError message = object
  [ "resultType" .= String "complete"
  , "content" .= [object ["type" .= String "text", "text" .= message]]
  , "structuredContent" .= object ["error" .= message]
  , "isError" .= True
  ]

compactText :: Value -> Text
compactText = TE.decodeUtf8 . BL.toStrict . encode

rpcResult :: Value -> Value -> Value
rpcResult rid result = object ["jsonrpc" .= String "2.0", "id" .= rid, "result" .= result]

rpcError :: Value -> Int -> Text -> Maybe Value -> Value
rpcError rid code message details = object
  [ "jsonrpc" .= String "2.0"
  , "id" .= rid
  , "error" .= object
      (["code" .= code, "message" .= message] <> maybe [] (pure . ("data" .=)) details)
  ]

lookupText :: Text -> Value -> Maybe Text
lookupText key (Object objectValue) = case KM.lookup (Key.fromText key) objectValue of
  Just (String textValue) -> Just textValue
  _ -> Nothing
lookupText _ _ = Nothing

lookupInt :: Text -> Value -> Maybe Int
lookupInt key (Object objectValue) = case KM.lookup (Key.fromText key) objectValue of
  Just jsonValue -> case fromJSON jsonValue of
    Success integer -> Just integer
    Error _ -> Nothing
  _ -> Nothing
lookupInt _ _ = Nothing
