{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Kadena.History.Persistence
  ( createDB
  , insertCompletedCommand
  , queryForExisting
  , selectCompletedCommands
  ) where

import Control.Monad

import qualified Data.Text as T
import qualified Data.Aeson as A
import Data.Text.Encoding (encodeUtf8)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BSL

import Data.List (sortBy)
import Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.Maybe

import Database.SQLite3.Direct

import qualified Pact.Types.Command as Pact
import Pact.Types.Runtime (TxId)
import Kadena.Types
import Kadena.Types.Sqlite
import Kadena.History.Types

data HistType = SCC | CCC deriving (Show, Eq)

htToField :: HistType -> SType
htToField SCC = SText $ Utf8 "smart_contract"
htToField CCC = SText $ Utf8 "config"

htFromField :: SType -> Either String HistType
htFromField s@(SText (Utf8 v))
  | v == "smart_contract" = Right SCC
  | v == "config" = Right CCC
  | otherwise = Left $ "unrecognized 'type' field in history db: " ++ show s
htFromField s = Left $ "unrecognized 'type' field in history db: " ++ show s

hashToField :: Hash -> SType
hashToField h = SText $ Utf8 $ BSL.toStrict $ A.encode h

crToField :: A.Value -> SType
crToField r = SText $ Utf8 $ BSL.toStrict $ A.encode r

latToField :: Maybe CmdResultLatencyMetrics -> SType
latToField r = SText $ Utf8 $ BSL.toStrict $ A.encode r

crFromField :: Hash -> LogIndex -> Maybe TxId -> ByteString -> ByteString -> CommandResult
crFromField hsh li tid cr lat = SmartContractResult hsh (Pact.CommandResult (Pact.RequestKey hsh) tid v) li lat'
  where
    lat' = case A.eitherDecodeStrict' lat of
      Left err -> error $ "crFromField: unable to decode CmdResultLatMetrics from database! " ++ show err ++ "\n" ++ show cr
      Right v' -> v'
    v = case A.eitherDecodeStrict' cr of
      Left err -> error $ "crFromField: unable to decode CommandResult from database! " ++ show err ++ "\n" ++ show cr
      Right v' -> v'

ccFromField :: Hash -> LogIndex -> ByteString -> ByteString -> CommandResult
ccFromField hsh li ccr lat = ConsensusConfigResult hsh v li lat'
  where
    lat' = case A.eitherDecodeStrict' lat of
      Left err -> error $ "ccFromField: unable to decode CmdResultLatMetrics from database! " ++ show err ++ "\n" ++ show ccr
      Right v' -> v'
    v = case A.eitherDecodeStrict' ccr of
      Left err -> error $ "ccFromField: unable to decode CommandResult from database! " ++ show err ++ "\n" ++ show ccr
      Right v' -> v'

sqlDbSchema :: Utf8
sqlDbSchema =
  "CREATE TABLE IF NOT EXISTS 'main'.'pactCommands' \
  \( 'hash' TEXT PRIMARY KEY NOT NULL UNIQUE\
  \, 'logIndex' INTEGER NOT NULL\
  \, 'txid' INTEGER NOT NULL\
  \, 'type' TEXT NOT NULL\
  \, 'result' TEXT NOT NULL\
  \, 'latency' TEXT NOT NULL\
  \)"

eitherToError :: Show e => String -> Either e a -> a
eitherToError _ (Right v) = v
eitherToError s (Left e) = error $ "SQLite Error in History exec: " ++ s ++ "\nWith Error: "++ show e

createDB :: FilePath -> IO DbEnv
createDB f = do
  conn' <- eitherToError "OpenDB" <$> open (Utf8 $ encodeUtf8 $ T.pack f)
  eitherToError "CreateTable" <$> exec conn' sqlDbSchema
  eitherToError "pragmas" <$> exec conn' "PRAGMA locking_mode = EXCLUSIVE"
  eitherToError "pragmas" <$> exec conn' "PRAGMA journal_mode = WAL"
  eitherToError "pragmas" <$> exec conn' "PRAGMA temp_store = MEMORY"
  DbEnv <$> pure conn'
        <*> prepStmt "createDB" conn' sqlInsertHistoryRow
        <*> prepStmt "createDB" conn' sqlQueryForExisting
        <*> prepStmt "createDB" conn' sqlSelectCompletedCommands

sqlInsertHistoryRow :: Utf8
sqlInsertHistoryRow =
    "INSERT INTO 'main'.'pactCommands' \
    \( 'hash'\
    \, 'logIndex' \
    \, 'txid' \
    \, 'type' \
    \, 'result'\
    \, 'latency'\
    \) VALUES (?,?,?,?,?)"

insertRow :: Statement -> CommandResult -> IO ()
insertRow s SmartContractResult{..} =
    execs "insertRow" s [hashToField _scrHash
            ,SInt $ fromIntegral _cmdrLogIndex
            ,SInt $ fromIntegral (fromMaybe (-1) (Pact._crTxId _scrResult))
            ,htToField SCC
            ,crToField (Pact._crResult _scrResult)
            ,latToField _cmdrLatMetrics]
insertRow s ConsensusConfigResult{..} =
    execs "insertRow" s [hashToField _ccrHash
            ,SInt $ fromIntegral _cmdrLogIndex
            ,SInt $ -1
            ,htToField CCC
            ,crToField $ A.toJSON _ccrResult
            ,latToField _cmdrLatMetrics]

insertCompletedCommand :: DbEnv -> [CommandResult] -> IO ()
insertCompletedCommand DbEnv{..} v = do
  let sortCmds a b = compare (_cmdrLogIndex a) (_cmdrLogIndex b)
  eitherToError "start insert transaction" <$> exec _conn "BEGIN TRANSACTION"
  mapM_ (insertRow _insertStatement) $ sortBy sortCmds v
  eitherToError "end insert transaction" <$> exec _conn "END TRANSACTION"

sqlQueryForExisting :: Utf8
sqlQueryForExisting = "SELECT EXISTS(SELECT 1 FROM 'main'.'pactCommands' WHERE hash=:hash LIMIT 1)"

queryForExisting :: DbEnv -> HashSet RequestKey -> IO (HashSet RequestKey)
queryForExisting e v = foldM f v v
  where
    f s rk = do
      r <- qrys "queryForExisting" (_qryExistingStmt e) [hashToField $ unRequestKey rk] [RInt]
      case r of
        [[SInt 1]] -> return s
        _ -> return $ HashSet.delete rk s

sqlSelectCompletedCommands :: Utf8
sqlSelectCompletedCommands =
  "SELECT logIndex,txid,type,result,latency FROM 'main'.'pactCommands' WHERE hash=:hash LIMIT 1"

selectCompletedCommands :: DbEnv -> HashSet RequestKey -> IO (HashMap RequestKey CommandResult)
selectCompletedCommands e v = foldM f HashMap.empty v
  where
    f m rk = do
      rs' <- qrys "selectCompletedCommands.1" (_qryCompletedStmt e) [hashToField $ unRequestKey rk] [RInt, RInt, RText, RText, RText]
      if null rs'
      then return m
      else case head rs' of
          [SInt li, SInt tid, type'@SText{}, SText (Utf8 cr),SText (Utf8 lat)] -> case htFromField type' of
              Left err -> dbError "selectCompletedCommands.2" $ "unmatched 'type': " ++ err ++ "\n## ROW ##\n" ++ show (head rs')
              Right SCC -> return $ HashMap.insert rk (crFromField (unRequestKey rk) (fromIntegral li) (if tid < 0 then Nothing else Just (fromIntegral tid)) cr lat) m
              Right CCC -> return $ HashMap.insert rk (ccFromField (unRequestKey rk) (fromIntegral li) cr lat) m
          r -> dbError "selectCompletedCommands.3" $ "Invalid result from query `History.selectCompletedCommands`: " ++ show r
