"""Runtime configuration, read from environment variables (prefix HY2M_)."""
import os
from dataclasses import dataclass


@dataclass
class Config:
    listen_host: str = "0.0.0.0"
    listen_port: int = 8080
    db_path: str = "data/hy2mgr.db"
    admin_user: str = "admin"
    admin_pass: str = ""  # empty => generated on first start and stored in DB
    api_token: str = ""  # static token for machine-to-machine API calls; empty => disabled
    public_url: str = ""  # e.g. https://panel.example.com, used to build subscription URLs
    sync_interval: int = 60  # seconds between traffic sync rounds
    session_ttl: int = 7 * 86400
    tls_cert: str = ""  # serve HTTPS directly when both cert and key are set
    tls_key: str = ""

    @classmethod
    def from_env(cls) -> "Config":
        c = cls()
        env = os.environ.get
        c.listen_host = env("HY2M_HOST", c.listen_host)
        c.listen_port = int(env("HY2M_PORT", c.listen_port))
        c.db_path = env("HY2M_DB", c.db_path)
        c.admin_user = env("HY2M_ADMIN_USER", c.admin_user)
        c.admin_pass = env("HY2M_ADMIN_PASS", c.admin_pass)
        c.api_token = env("HY2M_API_TOKEN", c.api_token)
        c.public_url = env("HY2M_PUBLIC_URL", c.public_url).rstrip("/")
        c.sync_interval = max(5, int(env("HY2M_SYNC_INTERVAL", c.sync_interval)))
        c.session_ttl = int(env("HY2M_SESSION_TTL", c.session_ttl))
        c.tls_cert = env("HY2M_TLS_CERT", c.tls_cert)
        c.tls_key = env("HY2M_TLS_KEY", c.tls_key)
        return c
