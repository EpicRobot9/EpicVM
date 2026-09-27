"""SQLite persistence with namespace and owner isolation on every query."""
from __future__ import annotations

import hashlib
import hmac
import os
import sqlite3
import time
import uuid


class MemoryStore:
    def __init__(self, path: str, identity_secret: str):
        self.db_path = path
        self.identity_secret = identity_secret.encode('utf-8')
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self._init()
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass

    def _owner_key(self, namespace: str, owner_id: str) -> str:
        material = f'{namespace}\0{owner_id}'.encode('utf-8')
        return hmac.new(self.identity_secret, material, hashlib.sha256).hexdigest()

    def _connect(self):
        conn = sqlite3.connect(self.db_path, timeout=10)
        conn.row_factory = sqlite3.Row
        return conn

    def _init(self):
        with self._connect() as conn:
            conn.executescript('''
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS memories (
                    id TEXT PRIMARY KEY, namespace TEXT NOT NULL, owner_key TEXT NOT NULL,
                    exact_text TEXT NOT NULL, category TEXT NOT NULL, source_message_id TEXT,
                    state TEXT NOT NULL DEFAULT 'active', supersedes_id TEXT,
                    reminded_by_id TEXT, parent_id TEXT, recall_count INTEGER NOT NULL DEFAULT 0,
                    last_recalled_at INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS memories_owner_active
                    ON memories(namespace, owner_key, state, updated_at DESC);
                CREATE TABLE IF NOT EXISTS conversations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, namespace TEXT NOT NULL,
                    owner_key TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL,
                    created_at INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS conversations_owner
                    ON conversations(namespace, owner_key, id DESC);
                CREATE TABLE IF NOT EXISTS memory_recalls (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, namespace TEXT NOT NULL,
                    owner_key TEXT NOT NULL, memory_id TEXT NOT NULL,
                    source_message_id TEXT, created_at INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS memory_recalls_owner
                    ON memory_recalls(namespace, owner_key, created_at DESC);
            ''')
            columns = {row['name'] for row in conn.execute('PRAGMA table_info(memories)')}
            for name, definition in (
                ('parent_id', 'TEXT'), ('recall_count', 'INTEGER NOT NULL DEFAULT 0'),
                ('last_recalled_at', 'INTEGER')):
                if name not in columns:
                    conn.execute(f'ALTER TABLE memories ADD COLUMN {name} {definition}')

    def list(self, namespace: str, owner_id: str, *, active_only=True, limit=50):
        owner = self._owner_key(namespace, owner_id)
        query = 'SELECT * FROM memories WHERE namespace=? AND owner_key=?'
        args = [namespace, owner]
        if active_only:
            query += " AND state='active'"
        query += ' ORDER BY updated_at DESC, rowid DESC LIMIT ?'
        args.append(max(1, min(int(limit), 200)))
        with self._connect() as conn:
            return [dict(row) for row in conn.execute(query, args)]

    def remember(self, namespace: str, owner_id: str, exact_text: str, category: str,
                 *, source_message_id=None, supersedes_id=None, reminded_by_id=None, parent_id=None):
        owner = self._owner_key(namespace, owner_id)
        now, memory_id = int(time.time()), uuid.uuid4().hex
        with self._connect() as conn:
            if parent_id:
                parent = conn.execute("SELECT id FROM memories WHERE id=? AND namespace=? AND owner_key=? AND state='active'",
                                      (parent_id, namespace, owner)).fetchone()
                parent_id = parent_id if parent else None
            if supersedes_id:
                conn.execute("UPDATE memories SET state='outdated',updated_at=? WHERE id=? AND namespace=? AND owner_key=?",
                             (now, supersedes_id, namespace, owner))
            conn.execute('''INSERT INTO memories
                (id,namespace,owner_key,exact_text,category,source_message_id,state,supersedes_id,reminded_by_id,parent_id,created_at,updated_at)
                VALUES (?,?,?,?,?,?, 'active',?,?,?,?,?)''',
                (memory_id, namespace, owner, exact_text, category, source_message_id,
                 supersedes_id, reminded_by_id, parent_id, now, now))
        return memory_id

    def record_recall(self, namespace: str, owner_id: str, memory_id: str, *, source_message_id=None):
        owner, now = self._owner_key(namespace, owner_id), int(time.time())
        with self._connect() as conn:
            row = conn.execute("SELECT id FROM memories WHERE id=? AND namespace=? AND owner_key=? AND state='active'",
                               (memory_id, namespace, owner)).fetchone()
            if not row:
                return False
            conn.execute('''UPDATE memories SET recall_count=recall_count+1,last_recalled_at=?
                WHERE id=? AND namespace=? AND owner_key=?''', (now, memory_id, namespace, owner))
            conn.execute('''INSERT INTO memory_recalls(namespace,owner_key,memory_id,source_message_id,created_at)
                VALUES (?,?,?,?,?)''', (namespace, owner, memory_id, source_message_id, now))
            return True

    def path(self, namespace: str, owner_id: str, memory_id: str, *, include_outdated=False):
        owner, path, seen = self._owner_key(namespace, owner_id), [], set()
        with self._connect() as conn:
            current = memory_id
            while current and current not in seen and len(path) < 24:
                seen.add(current)
                row = conn.execute('SELECT * FROM memories WHERE id=? AND namespace=? AND owner_key=?',
                                   (current, namespace, owner)).fetchone()
                if not row or (not include_outdated and row['state'] != 'active'):
                    break
                path.append(dict(row))
                current = row['parent_id']
        return list(reversed(path))

    def forget(self, namespace: str, owner_id: str, memory_id: str) -> bool:
        owner = self._owner_key(namespace, owner_id)
        with self._connect() as conn:
            cur = conn.execute('DELETE FROM memories WHERE id=? AND namespace=? AND owner_key=?',
                               (memory_id, namespace, owner))
            return cur.rowcount == 1

    def clear(self, namespace: str, owner_id: str):
        owner = self._owner_key(namespace, owner_id)
        with self._connect() as conn:
            conn.execute('DELETE FROM memories WHERE namespace=? AND owner_key=?', (namespace, owner))
            conn.execute('DELETE FROM conversations WHERE namespace=? AND owner_key=?', (namespace, owner))
            conn.execute('DELETE FROM memory_recalls WHERE namespace=? AND owner_key=?', (namespace, owner))

    def add_turn(self, namespace: str, owner_id: str, role: str, content: str):
        owner = self._owner_key(namespace, owner_id)
        with self._connect() as conn:
            conn.execute('INSERT INTO conversations(namespace,owner_key,role,content,created_at) VALUES (?,?,?,?,?)',
                         (namespace, owner, role, content, int(time.time())))

    def recent_turns(self, namespace: str, owner_id: str, limit=16):
        owner = self._owner_key(namespace, owner_id)
        with self._connect() as conn:
            rows = conn.execute('''SELECT role,content,created_at FROM conversations
                WHERE namespace=? AND owner_key=? ORDER BY id DESC LIMIT ?''',
                (namespace, owner, max(1, min(int(limit), 50)))).fetchall()
        return [dict(row) for row in reversed(rows)]
