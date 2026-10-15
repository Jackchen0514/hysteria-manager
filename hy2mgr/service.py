"""Business logic: user status, node auth, traffic sync, enforcement, subscriptions."""
import base64
import calendar
import datetime
import hashlib
import hmac
import logging
import secrets
import threading
import urllib.parse

from . import hy2
from .db import DB, gen_token, now

log = logging.getLogger("hy2mgr")

GB = 1024 ** 3


class Service:
    def __init__(self, cfg, db: DB):
        self.cfg = cfg
        self.db = db
        self._sync_lock = threading.Lock()
        self._stop = threading.Event()
        self.secret = db.get_setting("secret")
        if not self.secret:
            self.secret = secrets.token_hex(32)
            db.set_setting("secret", self.secret)
        if not cfg.admin_pass:
            stored = db.get_setting("admin_pass")
            if not stored:
                stored = secrets.token_urlsafe(12)
                db.set_setting("admin_pass", stored)
                log.warning("Generated admin password: %s  (set HY2M_ADMIN_PASS to override)", stored)
            cfg.admin_pass = stored

    # ---- admin auth ------------------------------------------------------
    def login(self, username, password):
        ok = hmac.compare_digest(username or "", self.cfg.admin_user) & \
            hmac.compare_digest(password or "", self.cfg.admin_pass)
        if not ok:
            return None
        exp = now() + self.cfg.session_ttl
        payload = "%s|%d" % (username, exp)
        sig = hmac.new(self.secret.encode(), payload.encode(), hashlib.sha256).hexdigest()
        return base64.urlsafe_b64encode(("%s|%s" % (payload, sig)).encode()).decode(), exp

    def check_token(self, token):
        if not token:
            return False
        if self.cfg.api_token and hmac.compare_digest(token, self.cfg.api_token):
            return True
        try:
            user, exp, sig = base64.urlsafe_b64decode(token.encode()).decode().rsplit("|", 2)
        except Exception:
            return False
        want = hmac.new(self.secret.encode(), ("%s|%s" % (user, exp)).encode(),
                        hashlib.sha256).hexdigest()
        return hmac.compare_digest(sig, want) and int(exp) > now() and user == self.cfg.admin_user

    # ---- users -----------------------------------------------------------
    @staticmethod
    def user_status(u, t=None):
        t = t or now()
        if not u["enabled"]:
            return "disabled"
        if u["expire_at"] and u["expire_at"] <= t:
            return "expired"
        if u["traffic_limit"] and u["upload"] + u["download"] >= u["traffic_limit"]:
            return "overlimit"
        return "active"

    def present_user(self, u):
        u = dict(u)
        u["used"] = u["upload"] + u["download"]
        u["remaining"] = max(0, u["traffic_limit"] - u["used"]) if u["traffic_limit"] else None
        u["status"] = self.user_status(u)
        u["enabled"] = bool(u["enabled"])
        u["subscription_url"] = self.sub_url(u)
        return u

    def sub_url(self, u):
        base = self.cfg.public_url or ""
        return "%s/sub/%s" % (base, u["sub_token"])

    def extend_user(self, username, days=0, seconds=0):
        """Add time. If already expired (or never set), count from now."""
        u = self.db.get_user(username)
        if not u:
            return None
        delta = int(days * 86400) + int(seconds)
        t = now()
        base = u["expire_at"] if u["expire_at"] > t else t
        new = max(t, base + delta) if delta >= 0 else max(0, u["expire_at"] + delta)
        return self.db.update_user(username, {"expire_at": new})

    def reset_traffic(self, username):
        return self.db.update_user(username, {"upload": 0, "download": 0, "last_reset_at": now()})

    def add_traffic_limit(self, username, delta_bytes):
        u = self.db.get_user(username)
        if not u:
            return None
        return self.db.update_user(username, {"traffic_limit": max(0, u["traffic_limit"] + int(delta_bytes))})

    def regenerate(self, username, password=True, sub=True):
        data = {}
        if password:
            data["password"] = gen_token(12)
        if sub:
            data["sub_token"] = gen_token(16)
        u = self.db.update_user(username, data)
        if password:
            self.kick_everywhere([username])
        return u

    # ---- hysteria2 http auth --------------------------------------------
    def authenticate(self, node_token, auth):
        node = self.db.get_node_by_token(node_token)
        if not node or not node["enabled"]:
            return False, ""
        u = self.db.get_user_by_password(auth or "")
        if not u or self.user_status(u) != "active":
            return False, ""
        return True, u["username"]

    # ---- traffic sync & enforcement -------------------------------------
    def kick_everywhere(self, usernames):
        for n in self.db.list_nodes(enabled_only=True):
            if not n["api_url"]:
                continue
            try:
                hy2.kick(n, usernames)
            except hy2.NodeAPIError as e:
                log.warning("kick on node %s failed: %s", n["name"], e)

    def sync_node(self, node):
        traffic = hy2.fetch_traffic(node, clear=True)
        t = now()
        with self.db.tx():
            for name, st in traffic.items():
                up, down = int(st.get("tx", 0)), int(st.get("rx", 0))
                if not up and not down:
                    continue
                u = self.db.q1("SELECT id, traffic_multiplier FROM users WHERE username=?", (name,))
                if not u:
                    continue
                # Quota and history use counted traffic (actual * per-user multiplier).
                m = u["traffic_multiplier"]
                up, down = int(round(up * m)), int(round(down * m))
                self.db.x("UPDATE users SET upload=upload+?, download=download+? WHERE id=?",
                          (up, down, u["id"]))
                self.db.x("INSERT INTO traffic_logs(user_id,node_id,upload,download,ts) "
                          "VALUES(?,?,?,?,?)", (u["id"], node["id"], up, down, t))
        online = hy2.fetch_online(node)
        # Kick connected users who are no longer allowed (expired / over limit / disabled / deleted)
        bad = []
        for name in online:
            u = self.db.get_user(name)
            if not u or self.user_status(u, t) != "active":
                bad.append(name)
        if bad:
            hy2.kick(node, bad)
            for name in bad:
                online.pop(name, None)
        self.db.update_node(node["id"], {"last_sync_at": t, "last_error": "",
                                         "online": sum(int(v) for v in online.values())})
        return {"users": len(traffic), "online": len(online), "kicked": bad}

    def sync_all(self):
        with self._sync_lock:
            self.auto_reset()
            # keep 180 days of per-sync traffic history
            self.db.x("DELETE FROM traffic_logs WHERE ts<?", (now() - 180 * 86400,))
            result = {}
            for n in self.db.list_nodes(enabled_only=True):
                if not n["api_url"]:
                    continue
                try:
                    result[n["id"]] = self.sync_node(n)
                except Exception as e:
                    log.warning("sync node %s failed: %s", n["name"], e)
                    self.db.update_node(n["id"], {"last_error": str(e)[:500]})
                    result[n["id"]] = {"error": str(e)}
            return result

    def auto_reset(self, today=None):
        """Monthly traffic reset for users with reset_day set."""
        today = today or datetime.datetime.now()
        reset = []
        for u in self.db.q("SELECT username, reset_day, last_reset_at FROM users WHERE reset_day>0"):
            y, m = today.year, today.month
            day = min(u["reset_day"], 28)
            if today.day < day:
                m -= 1
                if m == 0:
                    y, m = y - 1, 12
            boundary = int(datetime.datetime(y, m, min(day, calendar.monthrange(y, m)[1])).timestamp())
            if u["last_reset_at"] < boundary:
                self.reset_traffic(u["username"])
                reset.append(u["username"])
        if reset:
            log.info("auto reset traffic: %s", ", ".join(reset))
        return reset

    def run_loop(self):
        while not self._stop.wait(self.cfg.sync_interval):
            try:
                self.sync_all()
            except Exception:
                log.exception("sync loop error")

    def stop(self):
        self._stop.set()

    # ---- overview --------------------------------------------------------
    def stats(self):
        t = now()
        users = self.db.q("SELECT * FROM users")
        counts = {"total": len(users), "active": 0, "disabled": 0, "expired": 0, "overlimit": 0}
        for u in users:
            counts[self.user_status(u, t)] += 1
        nodes = self.db.list_nodes()
        tot = self.db.q1("SELECT COALESCE(SUM(upload),0) up, COALESCE(SUM(download),0) down FROM users")
        day = self.db.q1("SELECT COALESCE(SUM(upload),0) up, COALESCE(SUM(download),0) down "
                         "FROM traffic_logs WHERE ts>?", (t - 86400,))
        return {
            "users": counts,
            "nodes": {"total": len(nodes), "enabled": sum(1 for n in nodes if n["enabled"]),
                      "online_connections": sum(n["online"] for n in nodes)},
            "traffic": {"upload": tot["up"], "download": tot["down"],
                        "last_24h_upload": day["up"], "last_24h_download": day["down"]},
        }

    # ---- subscriptions ---------------------------------------------------
    @staticmethod
    def _split_port(port):
        port = str(port).strip()
        first = port.split(",")[0].split("-")[0]
        return int(first), (port if ("-" in port or "," in port) else "")

    def node_uri(self, node, u):
        q = {}
        if node["sni"]:
            q["sni"] = node["sni"]
        if node["insecure"]:
            q["insecure"] = "1"
        if node["obfs_password"]:
            q["obfs"] = "salamander"
            q["obfs-password"] = node["obfs_password"]
        host = node["address"]
        if ":" in host and not host.startswith("["):
            host = "[%s]" % host
        return "hysteria2://%s@%s:%s/%s#%s" % (
            urllib.parse.quote(u["password"], safe=""), host, node["port"],
            ("?" + urllib.parse.urlencode(q)) if q else "",
            urllib.parse.quote(node["name"]),
        )

    def links(self, u):
        return [self.node_uri(n, u) for n in self.db.list_nodes(enabled_only=True)]

    def clash_config(self, u):
        def s(v):
            return '"%s"' % str(v).replace("\\", "\\\\").replace('"', '\\"')
        nodes = self.db.list_nodes(enabled_only=True)
        lines = ["proxies:"]
        for n in nodes:
            port, ports = self._split_port(n["port"])
            lines += ["  - name: %s" % s(n["name"]), "    type: hysteria2",
                      "    server: %s" % s(n["address"]), "    port: %d" % port]
            if ports:
                lines.append("    ports: %s" % s(ports.replace(",", "/")))
            lines.append("    password: %s" % s(u["password"]))
            if n["sni"]:
                lines.append("    sni: %s" % s(n["sni"]))
            if n["insecure"]:
                lines.append("    skip-cert-verify: true")
            if n["obfs_password"]:
                lines += ["    obfs: salamander", "    obfs-password: %s" % s(n["obfs_password"])]
        if not nodes:
            lines[0] = "proxies: []"
        names = [s(n["name"]) for n in nodes]
        lines += ["proxy-groups:", "  - name: Proxy", "    type: select",
                  "    proxies: [%s]" % ", ".join(names + ['"DIRECT"']),
                  "rules:", "  - MATCH,Proxy"]
        return "\n".join(lines) + "\n"

    def userinfo_header(self, u):
        return "upload=%d; download=%d; total=%d; expire=%d" % (
            u["upload"], u["download"], u["traffic_limit"], u["expire_at"])

    def node_server_config(self, node, manager_url):
        """Example hysteria2 server config.yaml for a node."""
        listen_port, _ = self._split_port(node["port"])
        secret = node["api_secret"] or "CHANGE_ME"
        api_listen = ":9999"
        if node["api_url"]:
            p = urllib.parse.urlparse(node["api_url"])
            if p.port:
                api_listen = ":%d" % p.port
        cfg = [
            "listen: :%d" % listen_port,
            "",
            "# Use your own certificate, or replace with an `acme:` block",
            "tls:",
            "  cert: /etc/hysteria/server.crt",
            "  key: /etc/hysteria/server.key",
            "",
        ]
        if node["obfs_password"]:
            cfg += ["obfs:", "  type: salamander", "  salamander:",
                    "    password: %s" % node["obfs_password"], ""]
        cfg += [
            "auth:",
            "  type: http",
            "  http:",
            "    url: %s/hy2/auth/%s" % (manager_url.rstrip("/"), node["auth_token"]),
            "    insecure: false",
            "",
            "trafficStats:",
            "  listen: %s" % api_listen,
            "  secret: %s" % secret,
            "",
            "masquerade:",
            "  type: proxy",
            "  proxy:",
            "    url: https://www.bing.com/",
            "    rewriteHost: true",
        ]
        return "\n".join(cfg) + "\n"
