"""SQLite storage. All access goes through a single connection guarded by a lock."""
import os
import secrets
import sqlite3
import threading
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    username      TEXT NOT NULL UNIQUE,
    password      TEXT NOT NULL UNIQUE,          -- hysteria2 auth string
    sub_token     TEXT NOT NULL UNIQUE,          -- subscription link token
    enabled       INTEGER NOT NULL DEFAULT 1,
    expire_at     INTEGER NOT NULL DEFAULT 0,    -- unix seconds, 0 = never
    traffic_limit INTEGER NOT NULL DEFAULT 0,    -- bytes, 0 = unlimited
    upload        INTEGER NOT NULL DEFAULT 0,    -- bytes, client -> server
    download      INTEGER NOT NULL DEFAULT 0,    -- bytes, server -> client
    reset_day     INTEGER NOT NULL DEFAULT 0,    -- 1..28: auto reset traffic monthly on this day, 0 = off
    last_reset_at INTEGER NOT NULL DEFAULT 0,
    note          TEXT NOT NULL DEFAULT '',
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS nodes (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL,
    address      TEXT NOT NULL,                 -- host clients connect to
    port         TEXT NOT NULL DEFAULT '443',   -- may be a port-hopping range e.g. 20000-30000
    sni          TEXT NOT NULL DEFAULT '',
    insecure     INTEGER NOT NULL DEFAULT 0,
    obfs_password TEXT NOT NULL DEFAULT '',     -- salamander obfs, empty = off
    api_url      TEXT NOT NULL DEFAULT '',      -- hysteria trafficStats url, e.g. http://1.2.3.4:9999
    api_secret   TEXT NOT NULL DEFAULT '',
    auth_token   TEXT NOT NULL UNIQUE,          -- identifies the node when it calls our auth endpoint
    enabled      INTEGER NOT NULL DEFAULT 1,
    sort         INTEGER NOT NULL DEFAULT 0,
    last_sync_at INTEGER NOT NULL DEFAULT 0,
    last_error   TEXT NOT NULL DEFAULT '',
    online       INTEGER NOT NULL DEFAULT 0,
    created_at   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS traffic_logs (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id  INTEGER NOT NULL,
    node_id  INTEGER NOT NULL,
    upload   INTEGER NOT NULL,
    download INTEGER NOT NULL,
    ts       INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_traffic_logs_user_ts ON traffic_logs(user_id, ts);
"""

USER_FIELDS = (
    "username", "password", "enabled", "expire_at", "traffic_limit",
    "upload", "download", "reset_day", "note",
)
NODE_FIELDS = (
    "name", "address", "port", "sni", "insecure", "obfs_password",
    "api_url", "api_secret", "enabled", "sort",
)


def now() -> int:
    return int(time.time())


def gen_token(n: int = 16) -> str:
    return secrets.token_urlsafe(n)


class DB:
    def __init__(self, path: str):
        if path != ":memory:":
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self.conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA busy_timeout=5000")
        self.lock = threading.RLock()
        with self.lock:
            self.conn.executescript(SCHEMA)

    # ---- low level -------------------------------------------------------
    def q(self, sql, args=()):
        with self.lock:
            return [dict(r) for r in self.conn.execute(sql, args).fetchall()]

    def q1(self, sql, args=()):
        rows = self.q(sql, args)
        return rows[0] if rows else None

    def x(self, sql, args=()):
        with self.lock:
            return self.conn.execute(sql, args)

    def tx(self):
        """Usage: with db.tx(): ...  (BEGIN/COMMIT under the lock)."""
        return _Tx(self)

    # ---- settings --------------------------------------------------------
    def get_setting(self, key, default=None):
        r = self.q1("SELECT value FROM settings WHERE key=?", (key,))
        return r["value"] if r else default

    def set_setting(self, key, value):
        self.x("INSERT INTO settings(key,value) VALUES(?,?) "
               "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, str(value)))

    # ---- users -----------------------------------------------------------
    def list_users(self, search="", status="", limit=100, offset=0):
        where, args = [], []
        if search:
            where.append("(username LIKE ? OR note LIKE ?)")
            args += ["%" + search + "%"] * 2
        t = now()
        if status == "active":
            where.append("enabled=1 AND (expire_at=0 OR expire_at>?) "
                         "AND (traffic_limit=0 OR upload+download<traffic_limit)")
            args.append(t)
        elif status == "disabled":
            where.append("enabled=0")
        elif status == "expired":
            where.append("expire_at>0 AND expire_at<=?")
            args.append(t)
        elif status == "overlimit":
            where.append("traffic_limit>0 AND upload+download>=traffic_limit")
        w = ("WHERE " + " AND ".join(where)) if where else ""
        total = self.q1("SELECT COUNT(*) c FROM users " + w, args)["c"]
        rows = self.q("SELECT * FROM users %s ORDER BY id DESC LIMIT ? OFFSET ?" % w,
                      args + [limit, offset])
        return rows, total

    def get_user(self, username):
        return self.q1("SELECT * FROM users WHERE username=?", (username,))

    def get_user_by_password(self, password):
        return self.q1("SELECT * FROM users WHERE password=?", (password,))

    def get_user_by_sub(self, token):
        return self.q1("SELECT * FROM users WHERE sub_token=?", (token,))

    def create_user(self, data):
        t = now()
        row = {
            "username": data["username"],
            "password": data.get("password") or gen_token(12),
            "sub_token": gen_token(16),
            "enabled": int(bool(data.get("enabled", 1))),
            "expire_at": int(data.get("expire_at", 0)),
            "traffic_limit": int(data.get("traffic_limit", 0)),
            "upload": 0,
            "download": 0,
            "reset_day": int(data.get("reset_day", 0)),
            "last_reset_at": t,
            "note": data.get("note", ""),
            "created_at": t,
            "updated_at": t,
        }
        cols = ",".join(row)
        self.x("INSERT INTO users(%s) VALUES(%s)" % (cols, ",".join("?" * len(row))),
               tuple(row.values()))
        return self.get_user(row["username"])

    def update_user(self, username, data):
        sets = {k: v for k, v in data.items() if k in USER_FIELDS + ("sub_token", "last_reset_at")}
        if not sets:
            return self.get_user(username)
        sets["updated_at"] = now()
        self.x("UPDATE users SET %s WHERE username=?" % ",".join(k + "=?" for k in sets),
               tuple(sets.values()) + (username,))
        return self.get_user(sets.get("username", username))

    def delete_user(self, username):
        u = self.get_user(username)
        if u:
            with self.tx():
                self.x("DELETE FROM traffic_logs WHERE user_id=?", (u["id"],))
                self.x("DELETE FROM users WHERE id=?", (u["id"],))
        return u

    # ---- nodes -----------------------------------------------------------
    def list_nodes(self, enabled_only=False):
        w = "WHERE enabled=1" if enabled_only else ""
        return self.q("SELECT * FROM nodes %s ORDER BY sort, id" % w)

    def get_node(self, node_id):
        return self.q1("SELECT * FROM nodes WHERE id=?", (node_id,))

    def get_node_by_token(self, token):
        return self.q1("SELECT * FROM nodes WHERE auth_token=?", (token,))

    def create_node(self, data):
        row = {k: data[k] for k in NODE_FIELDS if k in data}
        row["auth_token"] = gen_token(16)
        row["created_at"] = now()
        cols = ",".join(row)
        cur = self.x("INSERT INTO nodes(%s) VALUES(%s)" % (cols, ",".join("?" * len(row))),
                     tuple(row.values()))
        return self.get_node(cur.lastrowid)

    def update_node(self, node_id, data):
        sets = {k: v for k, v in data.items()
                if k in NODE_FIELDS + ("last_sync_at", "last_error", "online", "auth_token")}
        if sets:
            self.x("UPDATE nodes SET %s WHERE id=?" % ",".join(k + "=?" for k in sets),
                   tuple(sets.values()) + (node_id,))
        return self.get_node(node_id)

    def delete_node(self, node_id):
        n = self.get_node(node_id)
        if n:
            self.x("DELETE FROM nodes WHERE id=?", (node_id,))
        return n


class _Tx:
    def __init__(self, db):
        self.db = db

    def __enter__(self):
        self.db.lock.acquire()
        self.db.conn.execute("BEGIN")
        return self.db

    def __exit__(self, et, ev, tb):
        try:
            self.db.conn.execute("ROLLBACK" if et else "COMMIT")
        finally:
            self.db.lock.release()
        return False
