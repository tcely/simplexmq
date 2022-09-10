{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Agent.Store.SQLite
  ( SQLiteStore (..),
    createSQLiteStore,
    connectSQLiteStore,

    -- * Queues and connections
    createNewConn,
    updateNewConnRcv,
    updateNewConnSnd,
    createRcvConn,
    createSndConn,
    getConn,
    getConnData,
    getRcvConn,
    deleteConn,
    upgradeRcvConnToDuplex,
    upgradeSndConnToDuplex,
    setRcvQueueStatus,
    setRcvQueueConfirmedE2E,
    setSndQueueStatus,
    getRcvQueue,
    setRcvQueueNtfCreds,
    getNextRcvQueue,
    getNextSndQueue,
    dbCreateNextRcvQueue,
    dbCreateNextSndQueue,
    setRcvQueueAction,
    switchCurrRcvQueue,
    switchCurrSndQueue,
    -- Confirmations
    createConfirmation,
    acceptConfirmation,
    getAcceptedConfirmation,
    removeConfirmations,
    setHandshakeVersion,
    -- Invitations - sent via Contact connections
    createInvitation,
    getInvitation,
    acceptInvitation,
    unacceptInvitation,
    deleteInvitation,
    -- Messages
    updateRcvIds,
    createRcvMsg,
    updateSndIds,
    createSndMsg,
    getPendingMsgData,
    getPendingMsgs,
    setMsgUserAck,
    getLastMsg,
    deleteMsg,
    -- Double ratchet persistence
    createRatchetX3dhKeys,
    getRatchetX3dhKeys,
    createRatchet,
    getRatchet,
    getSkippedMsgKeys,
    updateRatchet,
    -- Async commands
    createCommand,
    getPendingCommands,
    getPendingCommand,
    deleteCommand,
    -- Notification device token persistence
    createNtfToken,
    getSavedNtfToken,
    updateNtfTokenRegistration,
    updateDeviceToken,
    updateNtfMode,
    updateNtfToken,
    removeNtfToken,
    -- Notification subscription persistence
    getNtfSubscription,
    createNtfSubscription,
    supervisorUpdateNtfSubscription,
    supervisorUpdateNtfSubAction,
    updateNtfSubscription,
    setNullNtfSubscriptionAction,
    deleteNtfSubscription,
    getNextNtfSubNTFAction,
    getNextNtfSubSMPAction,
    getActiveNtfToken,
    getNtfRcvQueue,
    setConnectionNtfs,

    -- * utilities
    withConnection,
    withTransaction,
    firstRow,
    firstRow',
    maybeFirstRow,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (stateTVar)
import Control.Monad.Except
import Crypto.Random (ChaChaDRG, randomBytesGenerate)
import Data.Bifunctor (second)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base64.URL as U
import Data.Char (toLower)
import Data.Function (on)
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List (find, foldl', groupBy)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Database.SQLite.Simple (FromRow, NamedParam (..), Only (..), Query (..), SQLError, ToRow, field, (:.) (..))
import qualified Database.SQLite.Simple as DB
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.QQ (sql)
import Database.SQLite.Simple.ToField (ToField (..))
import qualified Database.SQLite3 as SQLite3
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite.Migrations (Migration)
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet (RatchetX448, SkippedMsgDiff (..), SkippedMsgKeys)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol (DeviceToken (..), NtfSubscriptionId, NtfTknStatus (..), NtfTokenId, SMPQueueNtf (..))
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Parsers (blobFieldParser, fromTextField_)
import Simplex.Messaging.Protocol (MsgBody, MsgFlags, NtfServer, ProtocolServer (..), RcvNtfDhSecret, SndPublicVerifyKey, pattern NtfServer)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport.Client (TransportHost)
import Simplex.Messaging.Util (bshow, eitherToMaybe, ($>>=), (<$$>))
import Simplex.Messaging.Version
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)
import System.IO (hFlush, stdout)
import UnliftIO.Exception (bracket)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

-- * SQLite Store implementation

data SQLiteStore = SQLiteStore
  { dbFilePath :: FilePath,
    dbConnection :: TMVar DB.Connection,
    dbNew :: Bool
  }

createSQLiteStore :: FilePath -> [Migration] -> Bool -> IO SQLiteStore
createSQLiteStore dbFilePath migrations yesToMigrations = do
  let dbDir = takeDirectory dbFilePath
  createDirectoryIfMissing False dbDir
  st <- connectSQLiteStore dbFilePath
  checkThreadsafe st
  migrateSchema st migrations yesToMigrations
  pure st

checkThreadsafe :: SQLiteStore -> IO ()
checkThreadsafe st = withConnection st $ \db -> do
  compileOptions <- DB.query_ db "pragma COMPILE_OPTIONS;" :: IO [[Text]]
  let threadsafeOption = find (T.isPrefixOf "THREADSAFE=") (concat compileOptions)
  case threadsafeOption of
    Just "THREADSAFE=0" -> confirmOrExit "SQLite compiled with non-threadsafe code."
    Nothing -> putStrLn "Warning: SQLite THREADSAFE compile option not found"
    _ -> return ()

migrateSchema :: SQLiteStore -> [Migration] -> Bool -> IO ()
migrateSchema st migrations yesToMigrations = withConnection st $ \db -> do
  Migrations.initialize db
  Migrations.get db migrations >>= \case
    Left e -> confirmOrExit $ "Database error: " <> e
    Right [] -> pure ()
    Right ms -> do
      unless (dbNew st) $ do
        unless yesToMigrations $
          confirmOrExit "The app has a newer version than the database - it will be backed up and upgraded."
        let f = dbFilePath st
        copyFile f (f <> ".bak")
      Migrations.run db ms

confirmOrExit :: String -> IO ()
confirmOrExit s = do
  putStrLn s
  putStr "Continue (y/N): "
  hFlush stdout
  ok <- getLine
  when (map toLower ok /= "y") exitFailure

connectSQLiteStore :: FilePath -> IO SQLiteStore
connectSQLiteStore dbFilePath = do
  dbNew <- not <$> doesFileExist dbFilePath
  dbConnection <- newTMVarIO =<< connectDB dbFilePath
  pure SQLiteStore {dbFilePath, dbConnection, dbNew}

connectDB :: FilePath -> IO DB.Connection
connectDB path = do
  dbConn <- DB.open path
  SQLite3.exec (DB.connectionHandle dbConn) . fromQuery $
    [sql|
      PRAGMA foreign_keys = ON;
      -- PRAGMA trusted_schema = OFF;
      PRAGMA secure_delete = ON;
      PRAGMA auto_vacuum = FULL;
    |]
  -- _printPragmas dbConn path
  pure dbConn

-- _printPragmas :: DB.Connection -> FilePath -> IO ()
-- _printPragmas db path = do
--   foreign_keys <- DB.query_ db "PRAGMA foreign_keys;" :: IO [[Int]]
--   print $ path <> " foreign_keys: " <> show foreign_keys
--   -- when run via sqlite-simple query for trusted_schema seems to return empty list
--   trusted_schema <- DB.query_ db "PRAGMA trusted_schema;" :: IO [[Int]]
--   print $ path <> " trusted_schema: " <> show trusted_schema
--   secure_delete <- DB.query_ db "PRAGMA secure_delete;" :: IO [[Int]]
--   print $ path <> " secure_delete: " <> show secure_delete
--   auto_vacuum <- DB.query_ db "PRAGMA auto_vacuum;" :: IO [[Int]]
--   print $ path <> " auto_vacuum: " <> show auto_vacuum

checkConstraint :: StoreError -> IO (Either StoreError a) -> IO (Either StoreError a)
checkConstraint err action = action `E.catch` (pure . Left . handleSQLError err)

handleSQLError :: StoreError -> SQLError -> StoreError
handleSQLError err e
  | DB.sqlError e == DB.ErrorConstraint = err
  | otherwise = SEInternal $ bshow e

withConnection :: SQLiteStore -> (DB.Connection -> IO a) -> IO a
withConnection SQLiteStore {dbConnection} =
  bracket
    (atomically $ takeTMVar dbConnection)
    (atomically . putTMVar dbConnection)

withTransaction :: forall a. SQLiteStore -> (DB.Connection -> IO a) -> IO a
withTransaction st action = withConnection st $ loop 500 2_000_000
  where
    loop :: Int -> Int -> DB.Connection -> IO a
    loop t tLim db =
      DB.withImmediateTransaction db (action db) `E.catch` \(e :: SQLError) ->
        if tLim > t && DB.sqlError e == DB.ErrorBusy
          then do
            threadDelay t
            loop (t * 9 `div` 8) (tLim - t) db
          else E.throwIO e

createConn_ ::
  TVar ChaChaDRG ->
  ConnData ->
  (ByteString -> IO ()) ->
  IO (Either StoreError ByteString)
createConn_ gVar cData create = checkConstraint SEConnDuplicate $ case cData of
  ConnData {connId = ""} -> createWithRandomId gVar create
  ConnData {connId} -> create connId $> Right connId

createNewConn :: DB.Connection -> TVar ChaChaDRG -> ConnData -> SConnectionMode c -> IO (Either StoreError ConnId)
createNewConn db gVar cData@ConnData {connAgentVersion, enableNtfs, duplexHandshake} cMode =
  createConn_ gVar cData $ \connId -> do
    DB.execute db "INSERT INTO connections (conn_id, conn_mode, smp_agent_version, enable_ntfs, duplex_handshake) VALUES (?, ?, ?, ?, ?)" (connId, cMode, connAgentVersion, enableNtfs, duplexHandshake)

updateNewConnRcv :: DB.Connection -> ConnId -> RcvQueue -> IO (Either StoreError ())
updateNewConnRcv db connId rq@RcvQueue {server} =
  getConn db connId $>>= \case
    (SomeConn _ NewConnection {}) -> updateConn
    (SomeConn _ RcvConnection {}) -> updateConn -- to allow retries
    (SomeConn c _) -> pure . Left . SEBadConnType $ connType c
  where
    updateConn :: IO (Either StoreError ())
    updateConn = do
      upsertServer_ db server
      void $ insertRcvQueue_ db connId rq
      pure $ Right ()

updateNewConnSnd :: DB.Connection -> ConnId -> SndQueue -> IO (Either StoreError ())
updateNewConnSnd db connId sq@SndQueue {server} =
  getConn db connId $>>= \case
    (SomeConn _ NewConnection {}) -> updateConn
    (SomeConn _ SndConnection {}) -> updateConn -- to allow retries
    (SomeConn c _) -> pure . Left . SEBadConnType $ connType c
  where
    updateConn :: IO (Either StoreError ())
    updateConn = do
      upsertServer_ db server
      void $ insertSndQueue_ db connId sq
      pure $ Right ()

createRcvConn :: DB.Connection -> TVar ChaChaDRG -> ConnData -> RcvQueue -> SConnectionMode c -> IO (Either StoreError ConnId)
createRcvConn db gVar cData@ConnData {connAgentVersion, enableNtfs, duplexHandshake} q@RcvQueue {server} cMode =
  createConn_ gVar cData $ \connId -> do
    upsertServer_ db server
    DB.execute db "INSERT INTO connections (conn_id, conn_mode, smp_agent_version, enable_ntfs, duplex_handshake) VALUES (?, ?, ?, ?, ?)" (connId, cMode, connAgentVersion, enableNtfs, duplexHandshake)
    void $ insertRcvQueue_ db connId q

createSndConn :: DB.Connection -> TVar ChaChaDRG -> ConnData -> SndQueue -> IO (Either StoreError ConnId)
createSndConn db gVar cData@ConnData {connAgentVersion, enableNtfs, duplexHandshake} q@SndQueue {server} = do
  createConn_ gVar cData $ \connId -> do
    upsertServer_ db server
    DB.execute db "INSERT INTO connections (conn_id, conn_mode, smp_agent_version, enable_ntfs, duplex_handshake) VALUES (?, ?, ?, ?, ?)" (connId, SCMInvitation, connAgentVersion, enableNtfs, duplexHandshake)
    -- TODO add queue ID in insertSndQueue_
    void $ insertSndQueue_ db connId q

getRcvConn :: DB.Connection -> SMPServer -> SMP.RecipientId -> IO (Either StoreError (RcvQueue, SomeConn))
getRcvConn db ProtocolServer {host, port} rcvId = runExceptT $ do
  (rq, connId) <-
    ExceptT . firstRow (\(qRow :. Only connId) -> (toRcvQueue qRow, connId)) SEConnNotFound $
      DB.query
        db
        [sql|
          SELECT q.host, q.port, s.key_hash,
            q.rcv_id, q.rcv_private_key, q.rcv_dh_secret, q.e2e_priv_key, q.e2e_dh_secret, q.snd_id, q.snd_key, q.status,
            q.rcv_queue_action, q.rcv_queue_action_ts, q.curr_rcv_queue, q.next_rcv_queue_id,
            q.ntf_public_key, q.ntf_private_key, q.ntf_id, q.rcv_ntf_dh_secret,
            q.smp_client_version, q.created_at, q.updated_at,
            q.conn_id
          FROM rcv_queues q
          INNER JOIN servers s ON q.host = s.host AND q.port = s.port
          WHERE q.host = ? AND q.port = ? AND q.rcv_id = ?
        |]
        (host, port, rcvId)
  conn <- ExceptT $ getConn db connId
  pure (rq, conn)

deleteConn :: DB.Connection -> ConnId -> IO ()
deleteConn db connId =
  DB.executeNamed
    db
    "DELETE FROM connections WHERE conn_id = :conn_id;"
    [":conn_id" := connId]

upgradeRcvConnToDuplex :: DB.Connection -> ConnId -> SndQueue -> IO (Either StoreError ())
upgradeRcvConnToDuplex db connId sq@SndQueue {server} =
  getConn db connId $>>= \case
    (SomeConn _ RcvConnection {}) -> do
      upsertServer_ db server
      -- TODO save with queue ID
      void $ insertSndQueue_ db connId sq
      pure $ Right ()
    (SomeConn c _) -> pure . Left . SEBadConnType $ connType c

upgradeSndConnToDuplex :: DB.Connection -> ConnId -> RcvQueue -> IO (Either StoreError ())
upgradeSndConnToDuplex db connId rq@RcvQueue {server} =
  getConn db connId $>>= \case
    SomeConn _ SndConnection {} -> do
      upsertServer_ db server
      void $ insertRcvQueue_ db connId rq
      pure $ Right ()
    SomeConn c _ -> pure . Left . SEBadConnType $ connType c

setRcvQueueStatus :: DB.Connection -> RcvQueue -> QueueStatus -> IO ()
setRcvQueueStatus db RcvQueue {rcvId, server = ProtocolServer {host, port}} status =
  -- ? return error if queue does not exist?
  DB.executeNamed
    db
    [sql|
      UPDATE rcv_queues
      SET status = :status
      WHERE host = :host AND port = :port AND rcv_id = :rcv_id;
    |]
    [":status" := status, ":host" := host, ":port" := port, ":rcv_id" := rcvId]

setRcvQueueConfirmedE2E :: DB.Connection -> RcvQueue -> C.APublicVerifyKey -> C.DhSecretX25519 -> Version -> IO ()
setRcvQueueConfirmedE2E db RcvQueue {rcvId, server = ProtocolServer {host, port}} sndPublicKey e2eDhSecret smpClientVersion =
  DB.executeNamed
    db
    [sql|
      UPDATE rcv_queues
      SET e2e_dh_secret = :e2e_dh_secret,
          snd_key = :snd_key,
          status = :status,
          smp_client_version = :smp_client_version
      WHERE host = :host AND port = :port AND rcv_id = :rcv_id
    |]
    [ ":status" := Confirmed,
      ":e2e_dh_secret" := e2eDhSecret,
      ":snd_key" := sndPublicKey,
      ":smp_client_version" := smpClientVersion,
      ":host" := host,
      ":port" := port,
      ":rcv_id" := rcvId
    ]

setSndQueueStatus :: DB.Connection -> SndQueue -> QueueStatus -> IO ()
setSndQueueStatus db SndQueue {sndId, server = ProtocolServer {host, port}} status =
  -- ? return error if queue does not exist?
  DB.executeNamed
    db
    [sql|
      UPDATE snd_queues
      SET status = :status
      WHERE host = :host AND port = :port AND snd_id = :snd_id;
    |]
    [":status" := status, ":host" := host, ":port" := port, ":snd_id" := sndId]

getRcvQueue :: DB.Connection -> ConnId -> IO (Either StoreError RcvQueue)
getRcvQueue db connId =
  maybe (Left SEConnNotFound) Right <$> getRcvQueueByConnId_ db connId

setRcvQueueNtfCreds :: DB.Connection -> ConnId -> Maybe ClientNtfCreds -> IO ()
setRcvQueueNtfCreds db connId clientNtfCreds =
  DB.execute
    db
    [sql|
      UPDATE rcv_queues
      SET ntf_public_key = ?, ntf_private_key = ?, ntf_id = ?, rcv_ntf_dh_secret = ?
      WHERE conn_id = ?
    |]
    (ntfPublicKey_, ntfPrivateKey_, notifierId_, rcvNtfDhSecret_, connId)
  where
    (ntfPublicKey_, ntfPrivateKey_, notifierId_, rcvNtfDhSecret_) = case clientNtfCreds of
      Just ClientNtfCreds {ntfPublicKey, ntfPrivateKey, notifierId, rcvNtfDhSecret} -> (Just ntfPublicKey, Just ntfPrivateKey, Just notifierId, Just rcvNtfDhSecret)
      Nothing -> (Nothing, Nothing, Nothing, Nothing)

getNextRcvQueue :: DB.Connection -> RcvQueue -> IO (Maybe RcvQueue)
getNextRcvQueue db RcvQueue {dbNextRcvQueueId} = case dbNextRcvQueueId of
  Just rqId ->
    maybeFirstRow toRcvQueue $
      DB.query
        db
        [sql|
          SELECT q.host, q.port, s.key_hash,
            q.rcv_id, q.rcv_private_key, q.rcv_dh_secret, q.e2e_priv_key, q.e2e_dh_secret, q.snd_id, q.snd_key, q.status,
            q.rcv_queue_action, q.rcv_queue_action_ts, q.curr_rcv_queue, q.next_rcv_queue_id,
            q.ntf_public_key, q.ntf_private_key, q.ntf_id, q.rcv_ntf_dh_secret,
            q.smp_client_version, q.created_at, q.updated_at
          FROM rcv_queues q
          INNER JOIN servers s ON q.host = s.host AND q.port = s.port
          WHERE q.rcv_queue_id = ? AND q.curr_rcv_queue = ?
        |]
        (rqId, False)
  _ -> pure Nothing

getNextSndQueue :: DB.Connection -> SndQueue -> IO (Maybe SndQueue)
getNextSndQueue db SndQueue {dbNextSndQueueId} = case dbNextSndQueueId of
  Just sqId ->
    maybeFirstRow toSndQueue $
      DB.query
        db
        [sql|
          SELECT q.host, q.port, s.key_hash,
            q.snd_id, q.snd_public_key, q.snd_private_key, q.e2e_pub_key, q.e2e_dh_secret, q.status,
            q.snd_queue_action, q.snd_queue_action_ts, q.curr_snd_queue, q.next_snd_queue_id,
            q.smp_client_version, q.created_at, q.updated_at
          FROM snd_queues q
          INNER JOIN servers s ON q.host = s.host AND q.port = s.port
          WHERE q.snd_queue_id = ? AND q.curr_snd_queue = ?
        |]
        (sqId, False)
  _ -> pure Nothing

dbCreateNextRcvQueue :: DB.Connection -> ConnId -> RcvQueue -> RcvQueue -> IO ()
dbCreateNextRcvQueue db connId RcvQueue {server = (SMPServer host port _), rcvId} rq' = do
  rqId <- insertRcvQueue_ db connId rq'
  DB.execute
    db
    [sql|
      UPDATE rcv_queues
      SET next_rcv_queue_id = ?
      WHERE host = ? AND port = ? AND rcv_id = ? AND curr_rcv_queue = ?
    |]
    (rqId, host, port, rcvId, True)

dbCreateNextSndQueue :: DB.Connection -> ConnId -> SndQueue -> SndQueue -> IO ()
dbCreateNextSndQueue db connId SndQueue {server = (SMPServer host port _), sndId} sq' = do
  sqId <- insertSndQueue_ db connId sq'
  DB.execute
    db
    [sql|
      UPDATE snd_queues
      SET next_snd_queue_id = ?
      WHERE host = ? AND port = ? AND snd_id = ? AND curr_snd_queue = ?
    |]
    (sqId, host, port, sndId, True)

setRcvQueueAction :: DB.Connection -> RcvQueue -> Maybe RcvQueueAction -> IO ()
setRcvQueueAction db RcvQueue {server = (SMPServer host port _), rcvId} rqAction_ = do
  ts <- getCurrentTime
  DB.execute
    db
    [sql|
      UPDATE rcv_queues
      SET rcv_queue_action = ?, rcv_queue_action_ts = ?
      WHERE host = ? AND port = ? AND rcv_id = ? AND curr_rcv_queue = ?
    |]
    (rqAction_, ts, host, port, rcvId, True)

switchCurrRcvQueue :: DB.Connection -> RcvQueue -> RcvQueue -> IO ()
switchCurrRcvQueue db RcvQueue {server = (SMPServer host port _), rcvId} RcvQueue {dbNextRcvQueueId} = do
  DB.execute db "DELETE FROM rcv_queues WHERE host = ? AND port = ? AND rcv_id = ? AND curr_rcv_queue = ?" (host, port, rcvId, True)
  DB.execute db "UPDATE rcv_queues SET curr_rcv_queue = ? WHERE rcv_queue_id = ? AND curr_rcv_queue = ?" (True, dbNextRcvQueueId, False)

switchCurrSndQueue :: DB.Connection -> SndQueue -> IO ()
switchCurrSndQueue db SndQueue {server = (SMPServer host port _), sndId, dbNextSndQueueId} = do
  DB.execute db "DELETE FROM snd_queues WHERE host = ? AND port = ? AND snd_id = ? AND curr_snd_queue = ?" (host, port, sndId, True)
  DB.execute db "UPDATE snd_queues SET curr_snd_queue = ? WHERE snd_queue_id = ? AND curr_snd_queue = ?" (True, dbNextSndQueueId, False)

type SMPConfirmationRow = (SndPublicVerifyKey, C.PublicKeyX25519, ConnInfo, Maybe [SMPQueueInfo], Maybe Version)

smpConfirmation :: SMPConfirmationRow -> SMPConfirmation
smpConfirmation (senderKey, e2ePubKey, connInfo, smpReplyQueues_, smpClientVersion_) =
  SMPConfirmation
    { senderKey,
      e2ePubKey,
      connInfo,
      smpReplyQueues = fromMaybe [] smpReplyQueues_,
      smpClientVersion = fromMaybe 1 smpClientVersion_
    }

createConfirmation :: DB.Connection -> TVar ChaChaDRG -> NewConfirmation -> IO (Either StoreError ConfirmationId)
createConfirmation db gVar NewConfirmation {connId, senderConf = SMPConfirmation {senderKey, e2ePubKey, connInfo, smpReplyQueues, smpClientVersion}, ratchetState} =
  createWithRandomId gVar $ \confirmationId ->
    DB.execute
      db
      [sql|
        INSERT INTO conn_confirmations
        (confirmation_id, conn_id, sender_key, e2e_snd_pub_key, ratchet_state, sender_conn_info, smp_reply_queues, smp_client_version, accepted) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0);
      |]
      (confirmationId, connId, senderKey, e2ePubKey, ratchetState, connInfo, smpReplyQueues, smpClientVersion)

acceptConfirmation :: DB.Connection -> ConfirmationId -> ConnInfo -> IO (Either StoreError AcceptedConfirmation)
acceptConfirmation db confirmationId ownConnInfo = do
  DB.executeNamed
    db
    [sql|
      UPDATE conn_confirmations
      SET accepted = 1,
          own_conn_info = :own_conn_info
      WHERE confirmation_id = :confirmation_id;
    |]
    [ ":own_conn_info" := ownConnInfo,
      ":confirmation_id" := confirmationId
    ]
  firstRow confirmation SEConfirmationNotFound $
    DB.query
      db
      [sql|
        SELECT conn_id, ratchet_state, sender_key, e2e_snd_pub_key, sender_conn_info, smp_reply_queues, smp_client_version
        FROM conn_confirmations
        WHERE confirmation_id = ?;
      |]
      (Only confirmationId)
  where
    confirmation ((connId, ratchetState) :. confRow) =
      AcceptedConfirmation
        { confirmationId,
          connId,
          senderConf = smpConfirmation confRow,
          ratchetState,
          ownConnInfo
        }

getAcceptedConfirmation :: DB.Connection -> ConnId -> IO (Either StoreError AcceptedConfirmation)
getAcceptedConfirmation db connId =
  firstRow confirmation SEConfirmationNotFound $
    DB.query
      db
      [sql|
        SELECT confirmation_id, ratchet_state, own_conn_info, sender_key, e2e_snd_pub_key, sender_conn_info, smp_reply_queues, smp_client_version
        FROM conn_confirmations
        WHERE conn_id = ? AND accepted = 1;
      |]
      (Only connId)
  where
    confirmation ((confirmationId, ratchetState, ownConnInfo) :. confRow) =
      AcceptedConfirmation
        { confirmationId,
          connId,
          senderConf = smpConfirmation confRow,
          ratchetState,
          ownConnInfo
        }

removeConfirmations :: DB.Connection -> ConnId -> IO ()
removeConfirmations db connId =
  DB.executeNamed
    db
    [sql|
      DELETE FROM conn_confirmations
      WHERE conn_id = :conn_id;
    |]
    [":conn_id" := connId]

setHandshakeVersion :: DB.Connection -> ConnId -> Version -> Bool -> IO ()
setHandshakeVersion db connId aVersion duplexHS =
  DB.execute db "UPDATE connections SET smp_agent_version = ?, duplex_handshake = ? WHERE conn_id = ?" (aVersion, duplexHS, connId)

createInvitation :: DB.Connection -> TVar ChaChaDRG -> NewInvitation -> IO (Either StoreError InvitationId)
createInvitation db gVar NewInvitation {contactConnId, connReq, recipientConnInfo} =
  createWithRandomId gVar $ \invitationId ->
    DB.execute
      db
      [sql|
        INSERT INTO conn_invitations
        (invitation_id,  contact_conn_id, cr_invitation, recipient_conn_info, accepted) VALUES (?, ?, ?, ?, 0);
      |]
      (invitationId, contactConnId, connReq, recipientConnInfo)

getInvitation :: DB.Connection -> InvitationId -> IO (Either StoreError Invitation)
getInvitation db invitationId =
  firstRow invitation SEInvitationNotFound $
    DB.query
      db
      [sql|
        SELECT contact_conn_id, cr_invitation, recipient_conn_info, own_conn_info, accepted
        FROM conn_invitations
        WHERE invitation_id = ?
          AND accepted = 0
      |]
      (Only invitationId)
  where
    invitation (contactConnId, connReq, recipientConnInfo, ownConnInfo, accepted) =
      Invitation {invitationId, contactConnId, connReq, recipientConnInfo, ownConnInfo, accepted}

acceptInvitation :: DB.Connection -> InvitationId -> ConnInfo -> IO ()
acceptInvitation db invitationId ownConnInfo =
  DB.executeNamed
    db
    [sql|
      UPDATE conn_invitations
      SET accepted = 1,
          own_conn_info = :own_conn_info
      WHERE invitation_id = :invitation_id
    |]
    [ ":own_conn_info" := ownConnInfo,
      ":invitation_id" := invitationId
    ]

unacceptInvitation :: DB.Connection -> InvitationId -> IO ()
unacceptInvitation db invitationId =
  DB.execute db "UPDATE conn_invitations SET accepted = 0, own_conn_info = NULL WHERE invitation_id = ?" (Only invitationId)

deleteInvitation :: DB.Connection -> ConnId -> InvitationId -> IO (Either StoreError ())
deleteInvitation db contactConnId invId =
  getConn db contactConnId $>>= \case
    SomeConn SCContact _ ->
      Right <$> DB.execute db "DELETE FROM conn_invitations WHERE contact_conn_id = ? AND invitation_id = ?" (contactConnId, invId)
    _ -> pure $ Left SEConnNotFound

updateRcvIds :: DB.Connection -> ConnId -> IO (InternalId, InternalRcvId, PrevExternalSndId, PrevRcvMsgHash)
updateRcvIds db connId = do
  (lastInternalId, lastInternalRcvId, lastExternalSndId, lastRcvHash) <- retrieveLastIdsAndHashRcv_ db connId
  let internalId = InternalId $ unId lastInternalId + 1
      internalRcvId = InternalRcvId $ unRcvId lastInternalRcvId + 1
  updateLastIdsRcv_ db connId internalId internalRcvId
  pure (internalId, internalRcvId, lastExternalSndId, lastRcvHash)

createRcvMsg :: DB.Connection -> ConnId -> RcvMsgData -> IO ()
createRcvMsg db connId rcvMsgData = do
  insertRcvMsgBase_ db connId rcvMsgData
  insertRcvMsgDetails_ db connId rcvMsgData
  updateHashRcv_ db connId rcvMsgData

updateSndIds :: DB.Connection -> ConnId -> IO (InternalId, InternalSndId, PrevSndMsgHash)
updateSndIds db connId = do
  (lastInternalId, lastInternalSndId, prevSndHash) <- retrieveLastIdsAndHashSnd_ db connId
  let internalId = InternalId $ unId lastInternalId + 1
      internalSndId = InternalSndId $ unSndId lastInternalSndId + 1
  updateLastIdsSnd_ db connId internalId internalSndId
  pure (internalId, internalSndId, prevSndHash)

createSndMsg :: DB.Connection -> ConnId -> SndMsgData -> IO ()
createSndMsg db connId sndMsgData = do
  insertSndMsgBase_ db connId sndMsgData
  insertSndMsgDetails_ db connId sndMsgData
  updateHashSnd_ db connId sndMsgData

getPendingMsgData :: DB.Connection -> ConnId -> InternalId -> IO (Either StoreError (Maybe RcvQueue, PendingMsgData))
getPendingMsgData db connId msgId = do
  rq_ <- getRcvQueueByConnId_ db connId
  (rq_,) <$$> firstRow pendingMsgData SEMsgNotFound getMsgData_
  where
    getMsgData_ =
      DB.query
        db
        [sql|
          SELECT m.msg_type, m.msg_flags, m.msg_body, m.internal_ts, s.curr_snd_queue
          FROM messages m
          JOIN snd_messages s ON s.conn_id = m.conn_id AND s.internal_id = m.internal_id
          WHERE m.conn_id = ? AND m.internal_id = ?
        |]
        (connId, msgId)
    pendingMsgData :: (AgentMessageType, Maybe MsgFlags, MsgBody, InternalTs, Bool) -> PendingMsgData
    pendingMsgData (msgType, msgFlags_, msgBody, internalTs, currSndQueue) =
      let msgFlags = fromMaybe SMP.noMsgFlags msgFlags_
       in PendingMsgData {msgId, msgType, msgFlags, msgBody, internalTs, currSndQueue}

getPendingMsgs :: DB.Connection -> ConnId -> Bool -> IO [InternalId]
getPendingMsgs db connId current =
  map fromOnly
    <$> DB.query db "SELECT internal_id FROM snd_messages WHERE conn_id = ? AND curr_snd_queue = ?" (connId, current)

setMsgUserAck :: DB.Connection -> ConnId -> InternalId -> IO (Either StoreError SMP.MsgId)
setMsgUserAck db connId agentMsgId = do
  DB.execute db "UPDATE rcv_messages SET user_ack = ? WHERE conn_id = ? AND internal_id = ?" (True, connId, agentMsgId)
  firstRow fromOnly SEMsgNotFound $
    DB.query db "SELECT broker_id FROM rcv_messages WHERE conn_id = ? AND internal_id = ?" (connId, agentMsgId)

getLastMsg :: DB.Connection -> ConnId -> SMP.MsgId -> IO (Maybe RcvMsg)
getLastMsg db connId msgId =
  maybeFirstRow rcvMsg $
    DB.query
      db
      [sql|
        SELECT
          r.internal_id, m.internal_ts, r.broker_id, r.broker_ts, r.external_snd_id, r.integrity,
          m.msg_body, r.user_ack
        FROM rcv_messages r
        JOIN messages m ON r.internal_id = m.internal_id
        JOIN connections c ON r.conn_id = c.conn_id AND c.last_internal_msg_id = r.internal_id
        WHERE r.conn_id = ? AND r.broker_id = ?
      |]
      (connId, msgId)
  where
    rcvMsg (agentMsgId, internalTs, brokerId, brokerTs, sndMsgId, integrity, msgBody, userAck) =
      let msgMeta = MsgMeta {recipient = (agentMsgId, internalTs), broker = (brokerId, brokerTs), sndMsgId, integrity}
       in RcvMsg {internalId = InternalId agentMsgId, msgMeta, msgBody, userAck}

deleteMsg :: DB.Connection -> ConnId -> InternalId -> IO ()
deleteMsg db connId msgId =
  DB.execute db "DELETE FROM messages WHERE conn_id = ? AND internal_id = ?;" (connId, msgId)

createRatchetX3dhKeys :: DB.Connection -> ConnId -> C.PrivateKeyX448 -> C.PrivateKeyX448 -> IO ()
createRatchetX3dhKeys db connId x3dhPrivKey1 x3dhPrivKey2 =
  DB.execute db "INSERT INTO ratchets (conn_id, x3dh_priv_key_1, x3dh_priv_key_2) VALUES (?, ?, ?)" (connId, x3dhPrivKey1, x3dhPrivKey2)

getRatchetX3dhKeys :: DB.Connection -> ConnId -> IO (Either StoreError (C.PrivateKeyX448, C.PrivateKeyX448))
getRatchetX3dhKeys db connId =
  fmap hasKeys $
    firstRow id SEX3dhKeysNotFound $
      DB.query db "SELECT x3dh_priv_key_1, x3dh_priv_key_2 FROM ratchets WHERE conn_id = ?" (Only connId)
  where
    hasKeys = \case
      Right (Just k1, Just k2) -> Right (k1, k2)
      _ -> Left SEX3dhKeysNotFound

createRatchet :: DB.Connection -> ConnId -> RatchetX448 -> IO ()
createRatchet db connId rc =
  DB.executeNamed
    db
    [sql|
      INSERT INTO ratchets (conn_id, ratchet_state)
      VALUES (:conn_id, :ratchet_state)
      ON CONFLICT (conn_id) DO UPDATE SET
        ratchet_state = :ratchet_state,
        x3dh_priv_key_1 = NULL,
        x3dh_priv_key_2 = NULL
    |]
    [":conn_id" := connId, ":ratchet_state" := rc]

getRatchet :: DB.Connection -> ConnId -> IO (Either StoreError RatchetX448)
getRatchet db connId =
  firstRow' ratchet SERatchetNotFound $ DB.query db "SELECT ratchet_state FROM ratchets WHERE conn_id = ?" (Only connId)
  where
    ratchet = maybe (Left SERatchetNotFound) Right . fromOnly

getSkippedMsgKeys :: DB.Connection -> ConnId -> IO SkippedMsgKeys
getSkippedMsgKeys db connId =
  skipped <$> DB.query db "SELECT header_key, msg_n, msg_key FROM skipped_messages WHERE conn_id = ?" (Only connId)
  where
    skipped ms = foldl' addSkippedKey M.empty ms
    addSkippedKey smks (hk, msgN, mk) = M.alter (Just . addMsgKey) hk smks
      where
        addMsgKey = maybe (M.singleton msgN mk) (M.insert msgN mk)

updateRatchet :: DB.Connection -> ConnId -> RatchetX448 -> SkippedMsgDiff -> IO ()
updateRatchet db connId rc skipped = do
  DB.execute db "UPDATE ratchets SET ratchet_state = ? WHERE conn_id = ?" (rc, connId)
  case skipped of
    SMDNoChange -> pure ()
    SMDRemove hk msgN ->
      DB.execute db "DELETE FROM skipped_messages WHERE conn_id = ? AND header_key = ? AND msg_n = ?" (connId, hk, msgN)
    SMDAdd smks ->
      forM_ (M.assocs smks) $ \(hk, mks) ->
        forM_ (M.assocs mks) $ \(msgN, mk) ->
          DB.execute db "INSERT INTO skipped_messages (conn_id, header_key, msg_n, msg_key) VALUES (?, ?, ?, ?)" (connId, hk, msgN, mk)

createCommand :: DB.Connection -> ConnId -> Maybe SMPServer -> ACommand 'Client -> IO AsyncCmdId
createCommand db connId (Just (SMPServer host port _)) command = do
  DB.execute
    db
    "INSERT INTO commands (host, port, conn_id, command) VALUES (?, ?, ?, ?)"
    (host, port, connId, serializeCommand command)
  insertedRowId db
createCommand db connId Nothing command = do
  DB.execute
    db
    "INSERT INTO commands (conn_id, command) VALUES (?, ?)"
    (connId, command)
  insertedRowId db

insertedRowId :: DB.Connection -> IO Int64
insertedRowId db = fromOnly . head <$> DB.query_ db "SELECT last_insert_rowid()"

getPendingCommands :: DB.Connection -> ConnId -> IO [(Maybe SMPServer, [AsyncCmdId])]
getPendingCommands db connId = do
  map (\ids -> (fst $ head ids, map snd ids)) . groupBy ((==) `on` fst) . map srvCmdId
    <$> DB.query
      db
      [sql|
        SELECT c.host, c.port, s.key_hash, c.command_id
        FROM commands c
        LEFT JOIN servers s ON s.host = c.host AND s.port = c.port
        WHERE conn_id = ?
        ORDER BY c.host, c.port, c.command_id ASC
      |]
      (Only connId)
  where
    srvCmdId (host, port, keyHash, cmdId) = (SMPServer <$> host <*> port <*> keyHash, cmdId)

getPendingCommand :: DB.Connection -> AsyncCmdId -> IO (Either StoreError (ConnId, ACmd))
getPendingCommand db msgId = do
  firstRow pendingCmd SECmdNotFound $
    DB.query
      db
      "SELECT conn_id, command FROM commands WHERE command_id = ?"
      (Only msgId)
  where
    pendingCmd :: (ConnId, ACmd) -> (ConnId, ACmd)
    pendingCmd (connId, commandStr) = (connId, commandStr)

deleteCommand :: DB.Connection -> AsyncCmdId -> IO ()
deleteCommand db cmdId =
  DB.execute db "DELETE FROM commands WHERE command_id = ?" (Only cmdId)

createNtfToken :: DB.Connection -> NtfToken -> IO ()
createNtfToken db NtfToken {deviceToken = DeviceToken provider token, ntfServer = srv@ProtocolServer {host, port}, ntfTokenId, ntfPubKey, ntfPrivKey, ntfDhKeys = (ntfDhPubKey, ntfDhPrivKey), ntfDhSecret, ntfTknStatus, ntfTknAction, ntfMode} = do
  upsertNtfServer_ db srv
  DB.execute
    db
    [sql|
      INSERT INTO ntf_tokens
        (provider, device_token, ntf_host, ntf_port, tkn_id, tkn_pub_key, tkn_priv_key, tkn_pub_dh_key, tkn_priv_dh_key, tkn_dh_secret, tkn_status, tkn_action, ntf_mode) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    |]
    ((provider, token, host, port, ntfTokenId, ntfPubKey, ntfPrivKey, ntfDhPubKey, ntfDhPrivKey, ntfDhSecret) :. (ntfTknStatus, ntfTknAction, ntfMode))

getSavedNtfToken :: DB.Connection -> IO (Maybe NtfToken)
getSavedNtfToken db = do
  maybeFirstRow ntfToken $
    DB.query_
      db
      [sql|
        SELECT s.ntf_host, s.ntf_port, s.ntf_key_hash,
          t.provider, t.device_token, t.tkn_id, t.tkn_pub_key, t.tkn_priv_key, t.tkn_pub_dh_key, t.tkn_priv_dh_key, t.tkn_dh_secret,
          t.tkn_status, t.tkn_action, t.ntf_mode
        FROM ntf_tokens t
        JOIN ntf_servers s USING (ntf_host, ntf_port)
      |]
  where
    ntfToken ((host, port, keyHash) :. (provider, dt, ntfTokenId, ntfPubKey, ntfPrivKey, ntfDhPubKey, ntfDhPrivKey, ntfDhSecret) :. (ntfTknStatus, ntfTknAction, ntfMode_)) =
      let ntfServer = NtfServer host port keyHash
          ntfDhKeys = (ntfDhPubKey, ntfDhPrivKey)
          ntfMode = fromMaybe NMPeriodic ntfMode_
       in NtfToken {deviceToken = DeviceToken provider dt, ntfServer, ntfTokenId, ntfPubKey, ntfPrivKey, ntfDhKeys, ntfDhSecret, ntfTknStatus, ntfTknAction, ntfMode}

updateNtfTokenRegistration :: DB.Connection -> NtfToken -> NtfTokenId -> C.DhSecretX25519 -> IO ()
updateNtfTokenRegistration db NtfToken {deviceToken = DeviceToken provider token, ntfServer = ProtocolServer {host, port}} tknId ntfDhSecret = do
  updatedAt <- getCurrentTime
  DB.execute
    db
    [sql|
      UPDATE ntf_tokens
      SET tkn_id = ?, tkn_dh_secret = ?, tkn_status = ?, tkn_action = ?, updated_at = ?
      WHERE provider = ? AND device_token = ? AND ntf_host = ? AND ntf_port = ?
    |]
    (tknId, ntfDhSecret, NTRegistered, Nothing :: Maybe NtfTknAction, updatedAt, provider, token, host, port)

updateDeviceToken :: DB.Connection -> NtfToken -> DeviceToken -> IO ()
updateDeviceToken db NtfToken {deviceToken = DeviceToken provider token, ntfServer = ProtocolServer {host, port}} (DeviceToken toProvider toToken) = do
  updatedAt <- getCurrentTime
  DB.execute
    db
    [sql|
      UPDATE ntf_tokens
      SET provider = ?, device_token = ?, tkn_status = ?, tkn_action = ?, updated_at = ?
      WHERE provider = ? AND device_token = ? AND ntf_host = ? AND ntf_port = ?
    |]
    (toProvider, toToken, NTRegistered, Nothing :: Maybe NtfTknAction, updatedAt, provider, token, host, port)

updateNtfMode :: DB.Connection -> NtfToken -> NotificationsMode -> IO ()
updateNtfMode db NtfToken {deviceToken = DeviceToken provider token, ntfServer = ProtocolServer {host, port}} ntfMode = do
  updatedAt <- getCurrentTime
  DB.execute
    db
    [sql|
      UPDATE ntf_tokens
      SET ntf_mode = ?, updated_at = ?
      WHERE provider = ? AND device_token = ? AND ntf_host = ? AND ntf_port = ?
    |]
    (ntfMode, updatedAt, provider, token, host, port)

updateNtfToken :: DB.Connection -> NtfToken -> NtfTknStatus -> Maybe NtfTknAction -> IO ()
updateNtfToken db NtfToken {deviceToken = DeviceToken provider token, ntfServer = ProtocolServer {host, port}} tknStatus tknAction = do
  updatedAt <- getCurrentTime
  DB.execute
    db
    [sql|
      UPDATE ntf_tokens
      SET tkn_status = ?, tkn_action = ?, updated_at = ?
      WHERE provider = ? AND device_token = ? AND ntf_host = ? AND ntf_port = ?
    |]
    (tknStatus, tknAction, updatedAt, provider, token, host, port)

removeNtfToken :: DB.Connection -> NtfToken -> IO ()
removeNtfToken db NtfToken {deviceToken = DeviceToken provider token, ntfServer = ProtocolServer {host, port}} =
  DB.execute
    db
    [sql|
      DELETE FROM ntf_tokens
      WHERE provider = ? AND device_token = ? AND ntf_host = ? AND ntf_port = ?
    |]
    (provider, token, host, port)

getNtfSubscription :: DB.Connection -> ConnId -> IO (Maybe (NtfSubscription, Maybe (NtfSubAction, NtfActionTs)))
getNtfSubscription db connId =
  maybeFirstRow ntfSubscription $
    DB.query
      db
      [sql|
        SELECT s.host, s.port, s.key_hash, ns.ntf_host, ns.ntf_port, ns.ntf_key_hash,
          nsb.smp_ntf_id, nsb.ntf_sub_id, nsb.ntf_sub_status, nsb.ntf_sub_action, nsb.ntf_sub_smp_action, nsb.ntf_sub_action_ts
        FROM ntf_subscriptions nsb
        JOIN servers s ON s.host = nsb.smp_host AND s.port = nsb.smp_port
        JOIN ntf_servers ns USING (ntf_host, ntf_port)
        WHERE nsb.conn_id = ?
      |]
      (Only connId)
  where
    ntfSubscription (smpHost, smpPort, smpKeyHash, ntfHost, ntfPort, ntfKeyHash, ntfQueueId, ntfSubId, ntfSubStatus, ntfAction_, smpAction_, actionTs_) =
      let smpServer = SMPServer smpHost smpPort smpKeyHash
          ntfServer = NtfServer ntfHost ntfPort ntfKeyHash
          action = case (ntfAction_, smpAction_, actionTs_) of
            (Just ntfAction, Nothing, Just actionTs) -> Just (NtfSubNTFAction ntfAction, actionTs)
            (Nothing, Just smpAction, Just actionTs) -> Just (NtfSubSMPAction smpAction, actionTs)
            _ -> Nothing
       in (NtfSubscription {connId, smpServer, ntfQueueId, ntfServer, ntfSubId, ntfSubStatus}, action)

createNtfSubscription :: DB.Connection -> NtfSubscription -> NtfSubAction -> NtfActionTs -> IO ()
createNtfSubscription db ntfSubscription action actionTs = do
  let NtfSubscription {connId, smpServer = (SMPServer host port _), ntfQueueId, ntfServer = (NtfServer ntfHost ntfPort _), ntfSubId, ntfSubStatus} = ntfSubscription
  DB.execute
    db
    [sql|
      INSERT INTO ntf_subscriptions
        (conn_id, smp_host, smp_port, smp_ntf_id, ntf_host, ntf_port, ntf_sub_id,
          ntf_sub_status, ntf_sub_action, ntf_sub_smp_action, ntf_sub_action_ts)
      VALUES (?,?,?,?,?,?,?,?,?,?,?)
    |]
    ( (connId, host, port, ntfQueueId, ntfHost, ntfPort, ntfSubId)
        :. (ntfSubStatus, ntfSubAction, ntfSubSMPAction, actionTs)
    )
  where
    (ntfSubAction, ntfSubSMPAction) = ntfSubAndSMPAction action

supervisorUpdateNtfSubscription :: DB.Connection -> NtfSubscription -> NtfSubAction -> NtfActionTs -> IO ()
supervisorUpdateNtfSubscription db NtfSubscription {connId, ntfQueueId, ntfServer = (NtfServer ntfHost ntfPort _), ntfSubId, ntfSubStatus} action actionTs = do
  updatedAt <- getCurrentTime
  DB.execute
    db
    [sql|
      UPDATE ntf_subscriptions
      SET smp_ntf_id = ?, ntf_host = ?, ntf_port = ?, ntf_sub_id = ?, ntf_sub_status = ?, ntf_sub_action = ?, ntf_sub_smp_action = ?, ntf_sub_action_ts = ?, updated_by_supervisor = ?, updated_at = ?
      WHERE conn_id = ?
    |]
    ((ntfQueueId, ntfHost, ntfPort, ntfSubId) :. (ntfSubStatus, ntfSubAction, ntfSubSMPAction, actionTs, True, updatedAt, connId))
  where
    (ntfSubAction, ntfSubSMPAction) = ntfSubAndSMPAction action

supervisorUpdateNtfSubAction :: DB.Connection -> ConnId -> NtfSubAction -> NtfActionTs -> IO ()
supervisorUpdateNtfSubAction db connId action actionTs = do
  updatedAt <- getCurrentTime
  DB.execute
    db
    [sql|
      UPDATE ntf_subscriptions
      SET ntf_sub_action = ?, ntf_sub_smp_action = ?, ntf_sub_action_ts = ?, updated_by_supervisor = ?, updated_at = ?
      WHERE conn_id = ?
    |]
    (ntfSubAction, ntfSubSMPAction, actionTs, True, updatedAt, connId)
  where
    (ntfSubAction, ntfSubSMPAction) = ntfSubAndSMPAction action

updateNtfSubscription :: DB.Connection -> NtfSubscription -> NtfSubAction -> NtfActionTs -> IO ()
updateNtfSubscription db NtfSubscription {connId, ntfQueueId, ntfServer = (NtfServer ntfHost ntfPort _), ntfSubId, ntfSubStatus} action actionTs = do
  r <- maybeFirstRow fromOnly $ DB.query db "SELECT updated_by_supervisor FROM ntf_subscriptions WHERE conn_id = ?" (Only connId)
  forM_ r $ \updatedBySupervisor -> do
    updatedAt <- getCurrentTime
    if updatedBySupervisor
      then
        DB.execute
          db
          [sql|
            UPDATE ntf_subscriptions
            SET smp_ntf_id = ?, ntf_sub_id = ?, ntf_sub_status = ?, updated_by_supervisor = ?, updated_at = ?
            WHERE conn_id = ?
          |]
          (ntfQueueId, ntfSubId, ntfSubStatus, False, updatedAt, connId)
      else
        DB.execute
          db
          [sql|
            UPDATE ntf_subscriptions
            SET smp_ntf_id = ?, ntf_host = ?, ntf_port = ?, ntf_sub_id = ?, ntf_sub_status = ?, ntf_sub_action = ?, ntf_sub_smp_action = ?, ntf_sub_action_ts = ?, updated_by_supervisor = ?, updated_at = ?
            WHERE conn_id = ?
          |]
          ((ntfQueueId, ntfHost, ntfPort, ntfSubId) :. (ntfSubStatus, ntfSubAction, ntfSubSMPAction, actionTs, False, updatedAt, connId))
  where
    (ntfSubAction, ntfSubSMPAction) = ntfSubAndSMPAction action

setNullNtfSubscriptionAction :: DB.Connection -> ConnId -> IO ()
setNullNtfSubscriptionAction db connId = do
  r <- maybeFirstRow fromOnly $ DB.query db "SELECT updated_by_supervisor FROM ntf_subscriptions WHERE conn_id = ?" (Only connId)
  forM_ r $ \updatedBySupervisor ->
    unless updatedBySupervisor $ do
      updatedAt <- getCurrentTime
      DB.execute
        db
        [sql|
          UPDATE ntf_subscriptions
          SET ntf_sub_action = ?, ntf_sub_smp_action = ?, ntf_sub_action_ts = ?, updated_by_supervisor = ?, updated_at = ?
          WHERE conn_id = ?
        |]
        (Nothing :: Maybe NtfSubNTFAction, Nothing :: Maybe NtfSubSMPAction, Nothing :: Maybe UTCTime, False, updatedAt, connId)

deleteNtfSubscription :: DB.Connection -> ConnId -> IO ()
deleteNtfSubscription db connId = do
  r <- maybeFirstRow fromOnly $ DB.query db "SELECT updated_by_supervisor FROM ntf_subscriptions WHERE conn_id = ?" (Only connId)
  forM_ r $ \updatedBySupervisor -> do
    updatedAt <- getCurrentTime
    if updatedBySupervisor
      then
        DB.execute
          db
          [sql|
            UPDATE ntf_subscriptions
            SET smp_ntf_id = ?, ntf_sub_id = ?, ntf_sub_status = ?, updated_by_supervisor = ?, updated_at = ?
            WHERE conn_id = ?
          |]
          (Nothing :: Maybe SMP.NotifierId, Nothing :: Maybe NtfSubscriptionId, NASDeleted, False, updatedAt, connId)
      else DB.execute db "DELETE FROM ntf_subscriptions WHERE conn_id = ?" (Only connId)

getNextNtfSubNTFAction :: DB.Connection -> NtfServer -> IO (Maybe (NtfSubscription, NtfSubNTFAction, NtfActionTs))
getNextNtfSubNTFAction db ntfServer@(NtfServer ntfHost ntfPort _) = do
  maybeFirstRow ntfSubAction getNtfSubAction_ $>>= \a@(NtfSubscription {connId}, _, _) -> do
    DB.execute db "UPDATE ntf_subscriptions SET updated_by_supervisor = ? WHERE conn_id = ?" (False, connId)
    pure $ Just a
  where
    getNtfSubAction_ =
      DB.query
        db
        [sql|
          SELECT ns.conn_id, s.host, s.port, s.key_hash,
            ns.smp_ntf_id, ns.ntf_sub_id, ns.ntf_sub_status, ns.ntf_sub_action_ts, ns.ntf_sub_action
          FROM ntf_subscriptions ns
          JOIN servers s ON s.host = ns.smp_host AND s.port = ns.smp_port
          WHERE ns.ntf_host = ? AND ns.ntf_port = ? AND ns.ntf_sub_action IS NOT NULL
          ORDER BY ns.ntf_sub_action_ts ASC
          LIMIT 1
        |]
        (ntfHost, ntfPort)
    ntfSubAction (connId, smpHost, smpPort, smpKeyHash, ntfQueueId, ntfSubId, ntfSubStatus, actionTs, action) =
      let smpServer = SMPServer smpHost smpPort smpKeyHash
          ntfSubscription = NtfSubscription {connId, smpServer, ntfQueueId, ntfServer, ntfSubId, ntfSubStatus}
       in (ntfSubscription, action, actionTs)

getNextNtfSubSMPAction :: DB.Connection -> SMPServer -> IO (Maybe (NtfSubscription, NtfSubSMPAction, NtfActionTs))
getNextNtfSubSMPAction db smpServer@(SMPServer smpHost smpPort _) = do
  maybeFirstRow ntfSubAction getNtfSubAction_ $>>= \a@(NtfSubscription {connId}, _, _) -> do
    DB.execute db "UPDATE ntf_subscriptions SET updated_by_supervisor = ? WHERE conn_id = ?" (False, connId)
    pure $ Just a
  where
    getNtfSubAction_ =
      DB.query
        db
        [sql|
          SELECT ns.conn_id, s.ntf_host, s.ntf_port, s.ntf_key_hash,
            ns.smp_ntf_id, ns.ntf_sub_id, ns.ntf_sub_status, ns.ntf_sub_action_ts, ns.ntf_sub_smp_action
          FROM ntf_subscriptions ns
          JOIN ntf_servers s USING (ntf_host, ntf_port)
          WHERE ns.smp_host = ? AND ns.smp_port = ? AND ns.ntf_sub_smp_action IS NOT NULL AND ns.ntf_sub_action_ts IS NOT NULL
          ORDER BY ns.ntf_sub_action_ts ASC
          LIMIT 1
        |]
        (smpHost, smpPort)
    ntfSubAction (connId, ntfHost, ntfPort, ntfKeyHash, ntfQueueId, ntfSubId, ntfSubStatus, actionTs, action) =
      let ntfServer = NtfServer ntfHost ntfPort ntfKeyHash
          ntfSubscription = NtfSubscription {connId, smpServer, ntfQueueId, ntfServer, ntfSubId, ntfSubStatus}
       in (ntfSubscription, action, actionTs)

getActiveNtfToken :: DB.Connection -> IO (Maybe NtfToken)
getActiveNtfToken db =
  maybeFirstRow ntfToken $
    DB.query
      db
      [sql|
        SELECT s.ntf_host, s.ntf_port, s.ntf_key_hash,
          t.provider, t.device_token, t.tkn_id, t.tkn_pub_key, t.tkn_priv_key, t.tkn_pub_dh_key, t.tkn_priv_dh_key, t.tkn_dh_secret,
          t.tkn_status, t.tkn_action, t.ntf_mode
        FROM ntf_tokens t
        JOIN ntf_servers s USING (ntf_host, ntf_port)
        WHERE t.tkn_status = ?
      |]
      (Only NTActive)
  where
    ntfToken ((host, port, keyHash) :. (provider, dt, ntfTokenId, ntfPubKey, ntfPrivKey, ntfDhPubKey, ntfDhPrivKey, ntfDhSecret) :. (ntfTknStatus, ntfTknAction, ntfMode_)) =
      let ntfServer = NtfServer host port keyHash
          ntfDhKeys = (ntfDhPubKey, ntfDhPrivKey)
          ntfMode = fromMaybe NMPeriodic ntfMode_
       in NtfToken {deviceToken = DeviceToken provider dt, ntfServer, ntfTokenId, ntfPubKey, ntfPrivKey, ntfDhKeys, ntfDhSecret, ntfTknStatus, ntfTknAction, ntfMode}

getNtfRcvQueue :: DB.Connection -> SMPQueueNtf -> IO (Either StoreError (ConnId, RcvNtfDhSecret))
getNtfRcvQueue db SMPQueueNtf {smpServer = (SMPServer host port _), notifierId} =
  firstRow' res SEConnNotFound $
    DB.query
      db
      [sql|
        SELECT conn_id, rcv_ntf_dh_secret
        FROM rcv_queues
        WHERE host = ? AND port = ? AND ntf_id = ?
      |]
      (host, port, notifierId)
  where
    res (connId, Just rcvNtfDhSecret) = Right (connId, rcvNtfDhSecret)
    res _ = Left SEConnNotFound

setConnectionNtfs :: DB.Connection -> ConnId -> Bool -> IO ()
setConnectionNtfs db connId enableNtfs =
  DB.execute db "UPDATE connections SET enable_ntfs = ? WHERE conn_id = ?" (enableNtfs, connId)

-- * Auxiliary helpers

instance ToField QueueStatus where toField = toField . serializeQueueStatus

instance FromField QueueStatus where fromField = fromTextField_ queueStatusT

instance ToField InternalRcvId where toField (InternalRcvId x) = toField x

instance FromField InternalRcvId where fromField x = InternalRcvId <$> fromField x

instance ToField InternalSndId where toField (InternalSndId x) = toField x

instance FromField InternalSndId where fromField x = InternalSndId <$> fromField x

instance ToField InternalId where toField (InternalId x) = toField x

instance FromField InternalId where fromField x = InternalId <$> fromField x

instance ToField AgentMessageType where toField = toField . smpEncode

instance FromField AgentMessageType where fromField = blobFieldParser smpP

instance ToField MsgIntegrity where toField = toField . strEncode

instance FromField MsgIntegrity where fromField = blobFieldParser strP

instance ToField SMPQueueUri where toField = toField . strEncode

instance FromField SMPQueueUri where fromField = blobFieldParser strP

instance ToField AConnectionRequestUri where toField = toField . strEncode

instance FromField AConnectionRequestUri where fromField = blobFieldParser strP

instance ConnectionModeI c => ToField (ConnectionRequestUri c) where toField = toField . strEncode

instance (E.Typeable c, ConnectionModeI c) => FromField (ConnectionRequestUri c) where fromField = blobFieldParser strP

instance ToField ConnectionMode where toField = toField . decodeLatin1 . strEncode

instance FromField ConnectionMode where fromField = fromTextField_ connModeT

instance ToField (SConnectionMode c) where toField = toField . connMode

instance FromField AConnectionMode where fromField = fromTextField_ $ fmap connMode' . connModeT

instance ToField MsgFlags where toField = toField . decodeLatin1 . smpEncode

instance FromField MsgFlags where fromField = fromTextField_ $ eitherToMaybe . smpDecode . encodeUtf8

instance ToField [SMPQueueInfo] where toField = toField . smpEncodeList

instance FromField [SMPQueueInfo] where fromField = blobFieldParser smpListP

instance ToField (NonEmpty TransportHost) where toField = toField . decodeLatin1 . strEncode

instance FromField (NonEmpty TransportHost) where fromField = fromTextField_ $ eitherToMaybe . strDecode . encodeUtf8

instance ToField RcvQueueAction where toField = toField . textEncode

instance FromField RcvQueueAction where fromField = fromTextField_ textDecode

instance ToField SndQueueAction where toField = toField . textEncode

instance FromField SndQueueAction where fromField = fromTextField_ textDecode

instance ToField (ACommand p) where toField = toField . serializeCommand

instance FromField ACmd where fromField = blobFieldParser dbCommandP

listToEither :: e -> [a] -> Either e a
listToEither _ (x : _) = Right x
listToEither e _ = Left e

firstRow :: (a -> b) -> e -> IO [a] -> IO (Either e b)
firstRow f e a = second f . listToEither e <$> a

maybeFirstRow :: Functor f => (a -> b) -> f [a] -> f (Maybe b)
maybeFirstRow f q = fmap f . listToMaybe <$> q

firstRow' :: (a -> Either e b) -> e -> IO [a] -> IO (Either e b)
firstRow' f e a = (f <=< listToEither e) <$> a

{- ORMOLU_DISABLE -}
-- SQLite.Simple only has these up to 10 fields, which is insufficient for some of our queries
instance (FromField a, FromField b, FromField c, FromField d, FromField e,
          FromField f, FromField g, FromField h, FromField i, FromField j,
          FromField k) =>
  FromRow (a,b,c,d,e,f,g,h,i,j,k) where
  fromRow = (,,,,,,,,,,) <$> field <*> field <*> field <*> field <*> field
                         <*> field <*> field <*> field <*> field <*> field
                         <*> field

instance (FromField a, FromField b, FromField c, FromField d, FromField e,
          FromField f, FromField g, FromField h, FromField i, FromField j,
          FromField k, FromField l) =>
  FromRow (a,b,c,d,e,f,g,h,i,j,k,l) where
  fromRow = (,,,,,,,,,,,) <$> field <*> field <*> field <*> field <*> field
                          <*> field <*> field <*> field <*> field <*> field
                          <*> field <*> field

instance (ToField a, ToField b, ToField c, ToField d, ToField e, ToField f,
          ToField g, ToField h, ToField i, ToField j, ToField k, ToField l) =>
  ToRow (a,b,c,d,e,f,g,h,i,j,k,l) where
  toRow (a,b,c,d,e,f,g,h,i,j,k,l) =
    [ toField a, toField b, toField c, toField d, toField e, toField f,
      toField g, toField h, toField i, toField j, toField k, toField l
    ]

{- ORMOLU_ENABLE -}

-- * Server upsert helper

upsertServer_ :: DB.Connection -> SMPServer -> IO ()
upsertServer_ dbConn ProtocolServer {host, port, keyHash} = do
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO servers (host, port, key_hash) VALUES (:host,:port,:key_hash)
      ON CONFLICT (host, port) DO UPDATE SET
        host=excluded.host,
        port=excluded.port,
        key_hash=excluded.key_hash;
    |]
    [":host" := host, ":port" := port, ":key_hash" := keyHash]

upsertNtfServer_ :: DB.Connection -> NtfServer -> IO ()
upsertNtfServer_ db ProtocolServer {host, port, keyHash} = do
  DB.executeNamed
    db
    [sql|
      INSERT INTO ntf_servers (ntf_host, ntf_port, ntf_key_hash) VALUES (:host,:port,:key_hash)
      ON CONFLICT (ntf_host, ntf_port) DO UPDATE SET
        ntf_host=excluded.ntf_host,
        ntf_port=excluded.ntf_port,
        ntf_key_hash=excluded.ntf_key_hash;
    |]
    [":host" := host, ":port" := port, ":key_hash" := keyHash]

-- * createRcvConn helpers

insertRcvQueue_ :: DB.Connection -> ConnId -> RcvQueue -> IO Int64
insertRcvQueue_ db connId RcvQueue {..} = do
  qId <- newQueueId_ <$> DB.query_ db "SELECT rcv_queue_id FROM rcv_queues ORDER BY rcv_queue_id DESC LIMIT 1"
  DB.execute
    db
    [sql|
      INSERT INTO rcv_queues
        (rcv_queue_id, host, port, rcv_id, conn_id, rcv_private_key, rcv_dh_secret, e2e_priv_key, e2e_dh_secret, snd_id, status, curr_rcv_queue, smp_client_version, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
    |]
    ((qId, host server, port server, rcvId, connId) :. (rcvPrivateKey, rcvDhSecret, e2ePrivKey, e2eDhSecret, sndId, status) :. (currRcvQueue, smpClientVersion, createdAt, updatedAt))
  pure qId

-- * createSndConn helpers

insertSndQueue_ :: DB.Connection -> ConnId -> SndQueue -> IO Int64
insertSndQueue_ db connId SndQueue {..} = do
  qId <- newQueueId_ <$> DB.query_ db "SELECT snd_queue_id FROM snd_queues ORDER BY snd_queue_id DESC LIMIT 1"
  DB.execute
    db
    [sql|
      INSERT INTO snd_queues
        (snd_queue_id, host, port, snd_id, conn_id, snd_public_key, snd_private_key, e2e_pub_key, e2e_dh_secret, status, curr_snd_queue, smp_client_version, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
    |]
    ((qId, host server, port server, sndId, connId, sndPublicKey, sndPrivateKey, e2ePubKey, e2eDhSecret, status) :. (currSndQueue, smpClientVersion, createdAt, updatedAt))
  pure qId

newQueueId_ :: [Only (Maybe Int64)] -> Int64
newQueueId_ [] = 1
newQueueId_ (Only maxId_ : _) = maybe 1 (+ 1) maxId_

-- * getConn helpers

getConn :: DB.Connection -> ConnId -> IO (Either StoreError SomeConn)
getConn db connId =
  getConnData db connId >>= \case
    Nothing -> pure $ Left SEConnNotFound
    Just (cData, cMode) -> do
      rq_ <- getRcvQueueByConnId_ db connId
      sq_ <- getSndQueueByConnId_ db connId
      case (rq_, sq_, cMode) of
        (Just rq, Just sq, CMInvitation) -> do
          rq' <- getNextRcvQueue db rq
          sq' <- getNextSndQueue db sq
          pure . Right $ SomeConn SCDuplex (DuplexConnection cData rq sq rq' sq')
        (Just rq, Nothing, CMInvitation) -> pure . Right $ SomeConn SCRcv (RcvConnection cData rq)
        (Nothing, Just sq, CMInvitation) -> pure . Right $ SomeConn SCSnd (SndConnection cData sq)
        (Just rq, Nothing, CMContact) -> pure . Right $ SomeConn SCContact (ContactConnection cData rq)
        (Nothing, Nothing, _) -> pure . Right $ SomeConn SCNew (NewConnection cData)
        _ -> pure $ Left SEConnNotFound

getConnData :: DB.Connection -> ConnId -> IO (Maybe (ConnData, ConnectionMode))
getConnData dbConn connId' =
  maybeFirstRow toConnData $
    DB.query dbConn "SELECT conn_id, conn_mode, smp_agent_version, enable_ntfs, duplex_handshake FROM connections WHERE conn_id = ?;" (Only connId')
  where
    toConnData (connId, cMode, connAgentVersion, enableNtfs_, duplexHandshake) = (ConnData {connId, connAgentVersion, enableNtfs = fromMaybe True enableNtfs_, duplexHandshake}, cMode)

type RcvQueueRow =
  ServerRow
    :. (SMP.RecipientId, SMP.RcvPrivateSignKey, SMP.RcvDhSecret, C.PrivateKeyX25519, Maybe C.DhSecretX25519, SMP.SenderId, Maybe C.APublicVerifyKey, QueueStatus)
    :. (Maybe RcvQueueAction, Maybe UTCTime, Bool, Maybe Int64)
    :. NtfCredsRow
    :. (Maybe Version, UTCTime, UTCTime)

type ServerRow = (NonEmpty TransportHost, String, C.KeyHash)

type NtfCredsRow = (Maybe SMP.NtfPublicVerifyKey, Maybe SMP.NtfPrivateSignKey, Maybe SMP.NotifierId, Maybe RcvNtfDhSecret)

toRcvQueue :: RcvQueueRow -> RcvQueue
toRcvQueue (srvRow :. (rcvId, rcvPrivateKey, rcvDhSecret, e2ePrivKey, e2eDhSecret, sndId, sndPublicKey, status) :. (rqAction_, rqActionTs_, currRcvQueue, dbNextRcvQueueId) :. ntfCredsRow :. (smpClientVersion_, createdAt, updatedAt)) =
  let server = toSMPServer srvRow
      smpClientVersion = fromMaybe 1 smpClientVersion_
      rcvQueueAction = (,) <$> rqAction_ <*> rqActionTs_
      clientNtfCreds = toNtfCreds ntfCredsRow
   in RcvQueue {server, rcvId, rcvPrivateKey, rcvDhSecret, e2ePrivKey, e2eDhSecret, sndId, sndPublicKey, status, rcvQueueAction, currRcvQueue, dbNextRcvQueueId, smpClientVersion, clientNtfCreds, createdAt, updatedAt}

toSMPServer :: ServerRow -> SMPServer
toSMPServer (host, port, keyHash) = SMPServer host port keyHash

toNtfCreds :: NtfCredsRow -> Maybe ClientNtfCreds
toNtfCreds (Just ntfPublicKey, Just ntfPrivateKey, Just notifierId, Just rcvNtfDhSecret) = Just $ ClientNtfCreds {ntfPublicKey, ntfPrivateKey, notifierId, rcvNtfDhSecret}
toNtfCreds _ = Nothing

getRcvQueueByConnId_ :: DB.Connection -> ConnId -> IO (Maybe RcvQueue)
getRcvQueueByConnId_ dbConn connId =
  maybeFirstRow toRcvQueue $
    DB.query
      dbConn
      [sql|
        SELECT q.host, q.port, s.key_hash,
          q.rcv_id, q.rcv_private_key, q.rcv_dh_secret, q.e2e_priv_key, q.e2e_dh_secret, q.snd_id, q.snd_key, q.status,
          q.rcv_queue_action, q.rcv_queue_action_ts, q.curr_rcv_queue, q.next_rcv_queue_id,
          q.ntf_public_key, q.ntf_private_key, q.ntf_id, q.rcv_ntf_dh_secret,
          q.smp_client_version, q.created_at, q.updated_at
        FROM rcv_queues q
        INNER JOIN servers s ON q.host = s.host AND q.port = s.port
        WHERE q.conn_id = ? AND q.curr_rcv_queue = ?
      |]
      (connId, True)

getSndQueueByConnId_ :: DB.Connection -> ConnId -> IO (Maybe SndQueue)
getSndQueueByConnId_ db connId =
  maybeFirstRow toSndQueue $
    DB.query
      db
      [sql|
        SELECT q.host, q.port, s.key_hash,
          q.snd_id, q.snd_public_key, q.snd_private_key, q.e2e_pub_key, q.e2e_dh_secret, q.status,
          q.snd_queue_action, q.snd_queue_action_ts, q.curr_snd_queue, q.next_snd_queue_id,
          q.smp_client_version, q.created_at, q.updated_at
        FROM snd_queues q
        INNER JOIN servers s ON q.host = s.host AND q.port = s.port
        WHERE q.conn_id = ? AND q.curr_snd_queue = ?
      |]
      (connId, True)

type SndQueueRow =
  ServerRow
    :. (SMP.SenderId, Maybe C.APublicVerifyKey, SMP.SndPrivateSignKey, Maybe C.PublicKeyX25519, C.DhSecretX25519, QueueStatus, Maybe SndQueueAction, Maybe UTCTime, Bool, Maybe Int64)
    :. (Version, UTCTime, UTCTime)

toSndQueue :: SndQueueRow -> SndQueue
toSndQueue (srvRow :. (sndId, sndPublicKey, sndPrivateKey, e2ePubKey, e2eDhSecret, status, sqAction_, sqActionTs_, currSndQueue, dbNextSndQueueId) :. (smpClientVersion, createdAt, updatedAt)) =
  let server = toSMPServer srvRow
      sndQueueAction = (,) <$> sqAction_ <*> sqActionTs_
   in SndQueue {server, sndId, sndPublicKey, sndPrivateKey, e2ePubKey, e2eDhSecret, status, sndQueueAction, currSndQueue, dbNextSndQueueId, smpClientVersion, createdAt, updatedAt}

-- * updateRcvIds helpers

retrieveLastIdsAndHashRcv_ :: DB.Connection -> ConnId -> IO (InternalId, InternalRcvId, PrevExternalSndId, PrevRcvMsgHash)
retrieveLastIdsAndHashRcv_ dbConn connId = do
  [(lastInternalId, lastInternalRcvId, lastExternalSndId, lastRcvHash)] <-
    DB.queryNamed
      dbConn
      [sql|
        SELECT last_internal_msg_id, last_internal_rcv_msg_id, last_external_snd_msg_id, last_rcv_msg_hash
        FROM connections
        WHERE conn_id = :conn_id;
      |]
      [":conn_id" := connId]
  return (lastInternalId, lastInternalRcvId, lastExternalSndId, lastRcvHash)

updateLastIdsRcv_ :: DB.Connection -> ConnId -> InternalId -> InternalRcvId -> IO ()
updateLastIdsRcv_ dbConn connId newInternalId newInternalRcvId =
  DB.executeNamed
    dbConn
    [sql|
      UPDATE connections
      SET last_internal_msg_id = :last_internal_msg_id,
          last_internal_rcv_msg_id = :last_internal_rcv_msg_id
      WHERE conn_id = :conn_id;
    |]
    [ ":last_internal_msg_id" := newInternalId,
      ":last_internal_rcv_msg_id" := newInternalRcvId,
      ":conn_id" := connId
    ]

-- * createRcvMsg helpers

insertRcvMsgBase_ :: DB.Connection -> ConnId -> RcvMsgData -> IO ()
insertRcvMsgBase_ dbConn connId RcvMsgData {msgMeta, msgType, msgFlags, msgBody, internalRcvId} = do
  let MsgMeta {recipient = (internalId, internalTs)} = msgMeta
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO messages
        ( conn_id, internal_id, internal_ts, internal_rcv_id, internal_snd_id, msg_type, msg_flags, msg_body)
      VALUES
        (:conn_id,:internal_id,:internal_ts,:internal_rcv_id,            NULL,:msg_type,:msg_flags,:msg_body);
    |]
    [ ":conn_id" := connId,
      ":internal_id" := internalId,
      ":internal_ts" := internalTs,
      ":internal_rcv_id" := internalRcvId,
      ":msg_type" := msgType,
      ":msg_flags" := msgFlags,
      ":msg_body" := msgBody
    ]

insertRcvMsgDetails_ :: DB.Connection -> ConnId -> RcvMsgData -> IO ()
insertRcvMsgDetails_ dbConn connId RcvMsgData {msgMeta, internalRcvId, internalHash, externalPrevSndHash} = do
  let MsgMeta {integrity, recipient, broker, sndMsgId} = msgMeta
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO rcv_messages
        ( conn_id, internal_rcv_id, internal_id, external_snd_id,
          broker_id, broker_ts,
          internal_hash, external_prev_snd_hash, integrity)
      VALUES
        (:conn_id,:internal_rcv_id,:internal_id,:external_snd_id,
         :broker_id,:broker_ts,
         :internal_hash,:external_prev_snd_hash,:integrity);
    |]
    [ ":conn_id" := connId,
      ":internal_rcv_id" := internalRcvId,
      ":internal_id" := fst recipient,
      ":external_snd_id" := sndMsgId,
      ":broker_id" := fst broker,
      ":broker_ts" := snd broker,
      ":internal_hash" := internalHash,
      ":external_prev_snd_hash" := externalPrevSndHash,
      ":integrity" := integrity
    ]

updateHashRcv_ :: DB.Connection -> ConnId -> RcvMsgData -> IO ()
updateHashRcv_ dbConn connId RcvMsgData {msgMeta, internalHash, internalRcvId} =
  DB.executeNamed
    dbConn
    -- last_internal_rcv_msg_id equality check prevents race condition in case next id was reserved
    [sql|
      UPDATE connections
      SET last_external_snd_msg_id = :last_external_snd_msg_id,
          last_rcv_msg_hash = :last_rcv_msg_hash
      WHERE conn_id = :conn_id
        AND last_internal_rcv_msg_id = :last_internal_rcv_msg_id;
    |]
    [ ":last_external_snd_msg_id" := sndMsgId (msgMeta :: MsgMeta),
      ":last_rcv_msg_hash" := internalHash,
      ":conn_id" := connId,
      ":last_internal_rcv_msg_id" := internalRcvId
    ]

-- * updateSndIds helpers

retrieveLastIdsAndHashSnd_ :: DB.Connection -> ConnId -> IO (InternalId, InternalSndId, PrevSndMsgHash)
retrieveLastIdsAndHashSnd_ dbConn connId = do
  [(lastInternalId, lastInternalSndId, lastSndHash)] <-
    DB.queryNamed
      dbConn
      [sql|
        SELECT last_internal_msg_id, last_internal_snd_msg_id, last_snd_msg_hash
        FROM connections
        WHERE conn_id = :conn_id;
      |]
      [":conn_id" := connId]
  return (lastInternalId, lastInternalSndId, lastSndHash)

updateLastIdsSnd_ :: DB.Connection -> ConnId -> InternalId -> InternalSndId -> IO ()
updateLastIdsSnd_ dbConn connId newInternalId newInternalSndId =
  DB.executeNamed
    dbConn
    [sql|
      UPDATE connections
      SET last_internal_msg_id = :last_internal_msg_id,
          last_internal_snd_msg_id = :last_internal_snd_msg_id
      WHERE conn_id = :conn_id;
    |]
    [ ":last_internal_msg_id" := newInternalId,
      ":last_internal_snd_msg_id" := newInternalSndId,
      ":conn_id" := connId
    ]

-- * createSndMsg helpers

insertSndMsgBase_ :: DB.Connection -> ConnId -> SndMsgData -> IO ()
insertSndMsgBase_ dbConn connId SndMsgData {..} = do
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO messages
        ( conn_id, internal_id, internal_ts, internal_rcv_id, internal_snd_id, msg_type, msg_flags, msg_body)
      VALUES
        (:conn_id,:internal_id,:internal_ts,            NULL,:internal_snd_id,:msg_type,:msg_flags,:msg_body);
    |]
    [ ":conn_id" := connId,
      ":internal_id" := internalId,
      ":internal_ts" := internalTs,
      ":internal_snd_id" := internalSndId,
      ":msg_type" := msgType,
      ":msg_flags" := msgFlags,
      ":msg_body" := msgBody
    ]

insertSndMsgDetails_ :: DB.Connection -> ConnId -> SndMsgData -> IO ()
insertSndMsgDetails_ dbConn connId SndMsgData {..} =
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO snd_messages
        ( conn_id, internal_snd_id, internal_id, internal_hash, previous_msg_hash, curr_snd_queue)
      VALUES
        (:conn_id,:internal_snd_id,:internal_id,:internal_hash,:previous_msg_hash,:curr_snd_queue);
    |]
    [ ":conn_id" := connId,
      ":internal_snd_id" := internalSndId,
      ":internal_id" := internalId,
      ":internal_hash" := internalHash,
      ":previous_msg_hash" := prevMsgHash,
      ":curr_snd_queue" := currSndQueue
    ]

updateHashSnd_ :: DB.Connection -> ConnId -> SndMsgData -> IO ()
updateHashSnd_ dbConn connId SndMsgData {..} =
  DB.executeNamed
    dbConn
    -- last_internal_snd_msg_id equality check prevents race condition in case next id was reserved
    [sql|
      UPDATE connections
      SET last_snd_msg_hash = :last_snd_msg_hash
      WHERE conn_id = :conn_id
        AND last_internal_snd_msg_id = :last_internal_snd_msg_id;
    |]
    [ ":last_snd_msg_hash" := internalHash,
      ":conn_id" := connId,
      ":last_internal_snd_msg_id" := internalSndId
    ]

-- create record with a random ID
createWithRandomId :: TVar ChaChaDRG -> (ByteString -> IO ()) -> IO (Either StoreError ByteString)
createWithRandomId gVar create = tryCreate 3
  where
    tryCreate :: Int -> IO (Either StoreError ByteString)
    tryCreate 0 = pure $ Left SEUniqueID
    tryCreate n = do
      id' <- randomId gVar 12
      E.try (create id') >>= \case
        Right _ -> pure $ Right id'
        Left e
          | DB.sqlError e == DB.ErrorConstraint -> tryCreate (n - 1)
          | otherwise -> pure . Left . SEInternal $ bshow e

randomId :: TVar ChaChaDRG -> Int -> IO ByteString
randomId gVar n = U.encode <$> (atomically . stateTVar gVar $ randomBytesGenerate n)

ntfSubAndSMPAction :: NtfSubAction -> (Maybe NtfSubNTFAction, Maybe NtfSubSMPAction)
ntfSubAndSMPAction (NtfSubNTFAction action) = (Just action, Nothing)
ntfSubAndSMPAction (NtfSubSMPAction action) = (Nothing, Just action)
