{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230223_files where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230223_files :: Query
m20230223_files =
  [sql|
CREATE TABLE xftp_servers (
  xftp_server_id INTEGER PRIMARY KEY,
  xftp_host TEXT NOT NULL,
  xftp_port TEXT NOT NULL,
  xftp_key_hash BLOB NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE(xftp_host, xftp_port, xftp_key_hash)
);

CREATE TABLE rcv_files (
  rcv_file_id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users ON DELETE CASCADE,
  size INTEGER NOT NULL,
  digest BLOB NOT NULL,
  key BLOB NOT NULL,
  nonce BLOB NOT NULL,
  chunk_size INTEGER NOT NULL,
  tmp_path TEXT NOT NULL,
  save_dir TEXT NOT NULL,
  save_path TEXT,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_rcv_files_user_id ON rcv_files(user_id);

CREATE TABLE rcv_file_chunks (
  rcv_file_chunk_id INTEGER PRIMARY KEY,
  rcv_file_id INTEGER NOT NULL REFERENCES rcv_files ON DELETE CASCADE,
  chunk_no INTEGER NOT NULL,
  chunk_size INTEGER NOT NULL,
  digest BLOB NOT NULL,
  tmp_path TEXT,
  delay INTEGER,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_rcv_file_chunks_rcv_file_id ON rcv_file_chunks(rcv_file_id);

CREATE TABLE rcv_file_chunk_replicas (
  rcv_file_chunk_replica_id INTEGER PRIMARY KEY,
  rcv_file_chunk_id INTEGER NOT NULL REFERENCES rcv_file_chunks ON DELETE CASCADE,
  replica_number INTEGER NOT NULL,
  xftp_server_id INTEGER NOT NULL REFERENCES xftp_servers ON DELETE CASCADE,
  replica_id BLOB NOT NULL,
  replica_key BLOB NOT NULL,
  received INTEGER NOT NULL DEFAULT 0,
  acknowledged INTEGER NOT NULL DEFAULT 0,
  retries INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_rcv_file_chunk_replicas_rcv_file_chunk_id ON rcv_file_chunk_replicas(rcv_file_chunk_id);
CREATE INDEX idx_rcv_file_chunk_replicas_xftp_server_id ON rcv_file_chunk_replicas(xftp_server_id);
|]