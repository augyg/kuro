{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module EvidenceSpec where

import Test.Hspec

import Control.Parallel.Strategies
import Data.Maybe (fromJust)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BSC
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Crypto.Random
import System.IO.Unsafe
import qualified Data.Serialize as S

import Juno.Types
import qualified Juno.Types.Log as Log
import qualified Juno.Types.Service.Log as Log
import qualified Juno.Service.Evidence as Ev

spec :: Spec
spec = describe "Evidence Service" testEvidence

testEvidence :: Spec
testEvidence = do
  undefined
--  it "Command" $ undefined `shouldBe` undefined


nodeIdLeader, nodeIdFollower, nodeIdClient :: NodeId
nodeIdLeader = NodeId "localhost" 10000 "tcp://127.0.0.1:10000" $ Alias "leader"
nodeIdFollower = NodeId "localhost" 10001 "tcp://127.0.0.1:10001" $ Alias "follower"
nodeIdClient = NodeId "localhost" 8000 "tcp://127.0.0.1:8000" $ Alias "client"

privKeyLeader, privKeyFollower, privKeyClient :: PrivateKey
privKeyLeader = maybe (error "bad leader key") id $ importPrivate "\204m\223Uo|\211.\144\131\&5Xmlyd$\165T\148\&11P\142m\249\253$\216\232\220c"
privKeyFollower = maybe (error "bad leader key") id $ importPrivate "$%\181\214\b\138\246(5\181%\199\186\185\t!\NUL\253'\t\ENQ\212^\236O\SOP\217\ACK\EOT\170<"
privKeyClient = maybe (error "bad leader key") id $ importPrivate "8H\r\198a;\US\249\233b\DLE\211nWy\176\193\STX\236\SUB\151\206\152\tm\205\205\234(\CAN\254\181"

pubKeyLeader, pubKeyFollower, pubKeyClient :: PublicKey
pubKeyLeader = maybe (error "bad leader key") id $ importPublic "f\t\167y\197\140\&2c.L\209;E\181\146\157\226\137\155$\GS(\189\215\SUB\199\r\158\224\FS\190|"
pubKeyFollower = maybe (error "bad leader key") id $ importPublic "\187\182\129\&4\139\197s\175Sc!\237\&8L \164J7u\184;\CANiC\DLE\243\ESC\206\249\SYN\189\ACK"
pubKeyClient = maybe (error "bad leader key") id $ importPublic "@*\228W(^\231\193\134\239\254s\ETBN\208\RS\137\201\208,bEk\213\221\185#\152\&7\237\234\DC1"

keySet :: KeySet
keySet = KeySet
  { _ksCluster = Map.fromList [(nodeIdLeader, pubKeyLeader),(nodeIdFollower, pubKeyFollower)]
  , _ksClient = Map.fromList [(nodeIdClient, pubKeyClient)] }

mkCmds :: Int -> Int -> [Command]
mkCmds cnt lenOfMsg' =
  let (cmds :: [Command]) = either error id . fromWire Nothing keySet <$> toWire nodeIdClient pubKeyClient privKeyClient <$> replicate cnt (mkCmd lenOfMsg')
  in cmds `seq` cmds

mkCmd :: Int -> Command
mkCmd i = Command
  { _cmdEntry = CommandEntry $ randomBytestring i
  , _cmdClientId = nodeIdClient
  , _cmdRequestId = RequestId 0
  , _cmdEncryptGroup = Nothing
  , _cmdProvenance = NewMsg }

getCmdSignedRPC :: LogEntry -> SignedRPC
getCmdSignedRPC LogEntry{ _leCommand = Command{ _cmdProvenance = ReceivedMsg{ _pDig = dig, _pOrig = bdy }}} =
  SignedRPC dig bdy
getCmdSignedRPC LogEntry{ _leCommand = Command{ _cmdProvenance = NewMsg }} =
  error "Invariant Failure: for a command to be in a log entry, it needs to have been received!"

testLogHashingSpeed :: [Command] -> Seq LogEntry
testLogHashingSpeed = Log.newEntriesToLog (Term 0) "" (LogIndex (-1))
{-# INLINE testLogHashingSpeed #-}

randomBytestring :: Int -> ByteString
randomBytestring lenOfByteString' = unsafePerformIO $ do
  g <- newGenIO :: IO SystemRandom
  case genBytes lenOfByteString' g of
    Left _ -> error "failed to make randome bytestring"
    Right (b,_) -> return $ b

testHashingNoEncoding :: Int -> ByteString -> ByteString
testHashingNoEncoding cnt b
  | cnt >= 1 = let b' = hash b in b' `seq` testHashingNoEncoding (cnt - 1) b'
  | otherwise = hash b
{-# INLINE testHashingNoEncoding #-}

-- AER Testing

createConvSucAER :: Term -> LogIndex -> ByteString -> NodeId -> AppendEntriesResponse
createConvSucAER ct lindex lhash nid =
  AppendEntriesResponse ct nid True True lindex lhash NewMsg

mkNodes :: [NodeId]
mkNodes = iterate (\n@(NodeId h p _ _) -> n {_port = p + 1
                                          , _fullAddr = "tcp://" ++ h ++ ":" ++ show (p+1)
                                          , _alias = Alias $ BSC.pack $ "node" ++ show (p+1-10001)})
                    (NodeId "127.0.0.1" 10001 "tcp://127.0.0.1:10001" $ Alias "node1")

mkKeySet :: Set NodeId -> KeySet
mkKeySet nids =
  let ks = KeySet
        { _ksCluster = Map.fromSet (\_ -> pubKeyFollower) nids
        , _ksClient = Map.fromList [(nodeIdClient, pubKeyClient)] }
  in ks `seq` ks

mkEvCache :: Seq LogEntry -> Ev.EvidenceCache
mkEvCache les =
  let ec = Ev.EvidenceCache
            { Ev.minLogIdx = _leLogIndex $ fromJust $ Log.seqHead les
            , Ev.maxLogIdx = _leLogIndex $ fromJust $ Log.seqTail les
            , Ev.lastLogTerm = _leTerm $ fromJust $ Log.seqTail les
            , Ev.hashes = _leHash <$> les
            }
  in (sum $ B.length <$> Ev.hashes ec) `seq` ec

mkEvidence :: Ev.EvidenceCache -> Set NodeId -> [AppendEntriesResponse]
mkEvidence ec nids =
  let lHash = fromJust $ Log.seqTail $ Ev.hashes ec
      lIndex = Ev.maxLogIdx ec
      lTerm = Ev.lastLogTerm ec
      ev = createConvSucAER lTerm lIndex lHash <$> Set.toList nids
  in (sum $ length . show <$> ev) `seq` ev

mkState :: Int -> Int -> Int -> Int -> (Ev.EvidenceState, Ev.EvidenceCache, [AppendEntriesResponse])
mkState clusterSize' quorumSize' logSize' msgSize' =
  let nodes = Set.fromList $ take clusterSize' mkNodes
      les = Log.newEntriesToLog (Term 0) "" (LogIndex 0) $ mkCmds logSize' msgSize'
      es = Ev.initEvidenceState nodes (LogIndex (-1))
      ec = mkEvCache les
      ev = mkEvidence ec nodes
      res = (es, ec, ev)
  in (length $ show res) `seq` res

signedEvidence :: [AppendEntriesResponse] -> [SignedRPC]
signedEvidence aers =
  let m = (\a -> rpcToSignedRPC (_aerNodeId a) pubKeyFollower privKeyFollower $ AER' a) <$> aers
  in (sum $ length . show <$> m) `seq` m

parallelVerify :: KeySet -> [SignedRPC] -> [AppendEntriesResponse]
parallelVerify ks msgs = (verifyAER ks <$> msgs) `using` parList rseq

verifyAER :: KeySet -> SignedRPC -> AppendEntriesResponse
verifyAER ks msg = case signedRPCtoRPC Nothing ks msg of
  Left v -> error $ "Invariant failure: " ++ v ++ "\n### msg ###\n" ++ show msg
  Right (AER' aer) -> aer

testWithCrypto :: (Ev.EvidenceState, Ev.EvidenceCache, [SignedRPC]) -> (Either Int LogIndex, Ev.EvidenceState)
testWithCrypto (es, ec, srpcs) = let ks = mkKeySet $ Ev._esUnconvincedNodes es in Ev._runEvidenceProcessTest (es, ec, parallelVerify ks srpcs)
