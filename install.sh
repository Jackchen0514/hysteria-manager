#!/usr/bin/env bash
# Hysteria2 Manager installer — Cloudflare DNS-01 (Let's Encrypt) certificates.
#
# One-liner (downloads the panel code automatically when needed):
#   bash <(curl -fsSL https://raw.githubusercontent.com/Jackchen0514/hysteria-manager/main/install.sh) all ...
#
#   bash install.sh panel  --domain panel.example.com --cf-token TOKEN --email you@mail.com
#   bash install.sh node   --domain hk.example.com    --cf-token TOKEN --email you@mail.com \
#                          --panel https://panel.example.com --api-token API_TOKEN [--name 香港]
#   bash install.sh all    --domain panel.example.com --node-domain hk.example.com --cf-token TOKEN --email you@mail.com
#   bash install.sh update [--no-hysteria] [--force]      (or: bash <(curl .../update.sh))
#   bash install.sh uninstall panel|node
#
# Missing values are asked interactively. Run with --help for every option.
#
# Cloudflare API token permissions: Zone -> Zone -> Read, Zone -> DNS -> Edit
# (My Profile -> API Tokens -> Create Token -> "Edit zone DNS" template, then add Zone:Read).
set -euo pipefail

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]:-$0}")"   # /dev/fd when run via bash <(curl ...)
SCRIPT_DIR="$(cd "$SCRIPT_DIR" 2>/dev/null && pwd)" || SCRIPT_DIR="$PWD"
PANEL_DIR=/opt/hy2mgr
PANEL_USER=hy2mgr
HY_BIN=/usr/local/bin/hysteria
HY_CONF_DIR=/etc/hysteria
HY_DATA_DIR=/var/lib/hysteria
HY_USER=hysteria
ACME_HOME="${HOME:-/root}/.acme.sh"
CF_API="${CF_API:-https://api.cloudflare.com/client/v4}"
REPO="${HY2M_REPO:-Jackchen0514/hysteria-manager}"
BRANCH="${HY2M_BRANCH:-main}"

# ---- options ---------------------------------------------------------------
MODE="${1:-}"; [ $# -gt 0 ] && shift
UNINSTALL_WHAT=""
if [ "$MODE" = uninstall ]; then UNINSTALL_WHAT="${1:-}"; [ $# -gt 0 ] && shift; fi
DOMAIN=""; NODE_DOMAIN=""; CF_TOKEN="${CF_TOKEN:-}"; EMAIL=""
PANEL_PORT=443; NODE_PORT=443; ADMIN_USER="admin"; ADMIN_PASS=""
PANEL_URL=""; API_TOKEN=""; NODE_NAME=""; OBFS=""; STATS_PORT=9999; PORT_SET=0; HOP=""; HOP_SET=0
HY_VERSION=latest; DNS_RECORD=1; UPDATE_HY=1; FORCE=0

usage() { cat <<'EOF'
Usage:
  install.sh panel  --domain panel.example.com --cf-token TOKEN --email you@mail.com
  install.sh node   --domain hk.example.com --cf-token TOKEN --email you@mail.com \
                    --panel https://panel.example.com --api-token API_TOKEN [--name 香港]
  install.sh all    --domain panel.example.com --node-domain hk.example.com --cf-token TOKEN --email you@mail.com
  install.sh update [--no-hysteria] [--force] [--hy-version V]
  install.sh uninstall panel|node

Cloudflare API token permissions: Zone -> Zone -> Read, Zone -> DNS -> Edit

Options:
  --domain D          panel: panel domain;  node: node domain
  --node-domain D     all: node domain (default: same as --domain)
  --cf-token T        Cloudflare API token (or env CF_TOKEN)
  --email E           ACME account email
  --panel-port P      panel HTTPS port (default 443)
  --port P            hysteria UDP port (default 443; on re-install the panel's value is kept)
  --admin-user U      panel admin user (default admin)
  --admin-pass P      panel admin password (default: random, kept on re-install)
  --panel URL         node: panel URL, e.g. https://panel.example.com
  --api-token T       node: panel API token (HY2M_API_TOKEN of the panel)
  --name N            node: display name (default: node domain)
  --obfs / --no-obfs  node: enable / disable salamander obfuscation (default: keep the panel's setting)
  --hop RANGE         node: port hopping, e.g. 20000-30000 ("" disables; default: keep the panel's setting)
  --stats-port P      node: hysteria traffic stats API port (default 9999)
  --hy-version V      hysteria version, e.g. v2.6.1 (default latest)
  --no-dns            don't create/update the Cloudflare A record
  --no-hysteria       update: don't upgrade the hysteria binary
  --force             update: reinstall the panel code even if already up to date
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2;;
    --node-domain) NODE_DOMAIN="$2"; shift 2;;
    --cf-token) CF_TOKEN="$2"; shift 2;;
    --email) EMAIL="$2"; shift 2;;
    --panel-port) PANEL_PORT="$2"; shift 2;;
    --port) NODE_PORT="$2"; PORT_SET=1; shift 2;;
    --admin-user) ADMIN_USER="$2"; shift 2;;
    --admin-pass) ADMIN_PASS="$2"; shift 2;;
    --panel) PANEL_URL="${2%/}"; shift 2;;
    --api-token) API_TOKEN="$2"; shift 2;;
    --name) NODE_NAME="$2"; shift 2;;
    --obfs) OBFS=1; shift;;
    --no-obfs) OBFS=0; shift;;
    --hop) HOP="$2"; HOP_SET=1; shift 2;;
    --stats-port) STATS_PORT="$2"; shift 2;;
    --hy-version) HY_VERSION="$2"; shift 2;;
    --no-dns) DNS_RECORD=0; shift;;
    --no-hysteria) UPDATE_HY=0; shift;;
    --force) FORCE=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1"; usage; exit 1;;
  esac
done

# ---- helpers ---------------------------------------------------------------
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_off=$'\e[0m'
info() { echo "${c_grn}==>${c_off} $*"; }
warn() { echo "${c_ylw}WARN:${c_off} $*" >&2; }
die()  { echo "${c_red}ERROR:${c_off} $*" >&2; exit 1; }
ask() {  # ask VAR "prompt" [secret]
  local __v="$1" __p="$2" __s="${3:-}" __a=""
  [ -n "${!__v}" ] && return
  [ -t 0 ] || die "missing value for $__p (non-interactive; pass it as an option)"
  if [ -n "$__s" ]; then read -rsp "$__p: " __a; echo; else read -rp "$__p: " __a; fi
  [ -n "$__a" ] || die "$__p is required"
  printf -v "$__v" '%s' "$__a"
}
rand() { python3 -c 'import secrets,string,sys; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(int(sys.argv[1]))))' "${1:-24}"; }
valid_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; }

need_root() { [ "$(id -u)" = 0 ] || die "please run as root"; }

install_pkgs() {
  local missing=()
  for p in "$@"; do command -v "$p" >/dev/null 2>&1 || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return
  info "installing packages: ${missing[*]}"
  if command -v apt-get >/dev/null; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
  elif command -v dnf >/dev/null; then dnf install -y -q "${missing[@]}"
  elif command -v yum >/dev/null; then yum install -y -q "${missing[@]}"
  elif command -v apk >/dev/null; then apk add -q "${missing[@]}"
  else die "cannot install ${missing[*]}: unknown package manager"; fi
}

public_ip() {
  curl -fsS4 -m 10 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' \
    || curl -fsS4 -m 10 https://api.ipify.org
}

# Cloudflare API helper (python for JSON handling). Usage: cf verify | cf zone DOMAIN | cf upsert DOMAIN IP
cf() {
  CF_TOKEN="$CF_TOKEN" CF_API="$CF_API" python3 - "$@" <<'PY'
import json, os, sys, urllib.request, urllib.error
api, tok = os.environ["CF_API"], os.environ["CF_TOKEN"]
def call(method, path, body=None):
    req = urllib.request.Request(api + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try:
            d = json.load(e)
        except Exception:
            d = {"errors": [{"message": "HTTP %d" % e.code}]}
        sys.exit("cloudflare: " + "; ".join(x.get("message", "") for x in d.get("errors", [])))
def zone(domain):
    labels = domain.split(".")
    for i in range(len(labels) - 1):
        r = call("GET", "/zones?name=" + ".".join(labels[i:]))
        if r.get("result"):
            return r["result"][0]["id"]
    sys.exit("cloudflare: no zone found for %s (token lacks Zone:Read, or the domain is not on this account)" % domain)
cmd = sys.argv[1]
if cmd == "verify":
    r = call("GET", "/user/tokens/verify")
    if r.get("result", {}).get("status") != "active":
        sys.exit("cloudflare: token is not active")
elif cmd == "zone":
    print(zone(sys.argv[2]))
elif cmd == "upsert":
    name, ip = sys.argv[2], sys.argv[3]
    zid = zone(name)
    recs = call("GET", "/zones/%s/dns_records?type=A&name=%s" % (zid, name))["result"]
    body = {"type": "A", "name": name, "content": ip, "ttl": 1, "proxied": False}
    if not recs:
        call("POST", "/zones/%s/dns_records" % zid, body)
        print("created A %s -> %s" % (name, ip))
    elif recs[0]["content"] == ip and not recs[0]["proxied"]:
        print("A %s -> %s already set" % (name, ip))
    else:
        call("PUT", "/zones/%s/dns_records/%s" % (zid, recs[0]["id"]), body)
        print("updated A %s: %s%s -> %s (DNS only)" % (name, recs[0]["content"],
              " (proxied)" if recs[0]["proxied"] else "", ip))
PY
}

setup_cloudflare() {  # setup_cloudflare DOMAIN...
  ask CF_TOKEN "Cloudflare API token" secret
  info "verifying Cloudflare token"
  cf verify
  if [ "$DNS_RECORD" = 1 ]; then
    local ip; ip="$(public_ip)" || die "cannot detect public IPv4 (use --no-dns and set the record yourself)"
    for d in "$@"; do cf upsert "$d" "$ip"; done
  fi
}

open_port() {  # open_port PORT tcp|udp [from-ip]
  local port="$1" proto="$2" from="${3:-}"
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    if [ -n "$from" ]; then ufw allow from "$from" to any port "$port" proto "$proto" >/dev/null
    else ufw allow "$port/$proto" >/dev/null; fi
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    if [ -n "$from" ]; then
      firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$from port port=$port protocol=$proto accept" >/dev/null
    else firewall-cmd --permanent --add-port="$port/$proto" >/dev/null; fi
    firewall-cmd --reload >/dev/null
  fi
}

# ---- source code -----------------------------------------------------------
latest_sha() {
  curl -fsSL -m 15 -H "Accept: application/vnd.github.sha" "https://api.github.com/repos/$REPO/commits/$BRANCH" 2>/dev/null
}

# Sets SRC_DIR (contains hy2mgr/) and SRC_SHA (commit, may be empty if unknown).
fetch_source() {
  if [ -f "$SCRIPT_DIR/hy2mgr/__main__.py" ]; then
    SRC_DIR="$SCRIPT_DIR"
    SRC_SHA="${HY2M_SRC_SHA:-$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)}"
    return
  fi
  SRC_SHA="$(latest_sha || true)"
  local url="https://github.com/$REPO/archive/${SRC_SHA:-refs/heads/$BRANCH}.tar.gz"
  info "downloading panel code ${SRC_SHA:0:7}"
  SRC_DIR="$(mktemp -d)"
  curl -fsSL "$url" | tar -xz -C "$SRC_DIR" --strip-components=1 || die "download failed: $url"
  [ -f "$SRC_DIR/hy2mgr/__main__.py" ] || die "downloaded archive does not contain hy2mgr/"
}

copy_panel_code() {
  rm -rf "$PANEL_DIR/hy2mgr"
  cp -r "$SRC_DIR/hy2mgr" "$PANEL_DIR/"
  find "$PANEL_DIR/hy2mgr" -name __pycache__ -prune -exec rm -rf {} +
  if [ -n "$SRC_SHA" ]; then echo "$SRC_SHA" > "$PANEL_DIR/VERSION"; fi
}

write_panel_unit() {
  cat > /etc/systemd/system/hy2mgr.service <<EOF
[Unit]
Description=Hysteria2 Manager
After=network-online.target
Wants=network-online.target

[Service]
User=$PANEL_USER
Group=$PANEL_USER
WorkingDirectory=$PANEL_DIR
EnvironmentFile=$PANEL_DIR/.env
ExecStart=$(command -v python3) -m hy2mgr
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

env_get() { sed -n "s/^$1=//p" "$PANEL_DIR/.env" 2>/dev/null | head -1; }

# wait_panel: health check against the local panel using the values in .env
wait_panel() {
  local url host port tok
  url="$(env_get HY2M_PUBLIC_URL)"; port="$(env_get HY2M_PORT)"; tok="$(env_get HY2M_API_TOKEN)"
  host="$(echo "$url" | sed -E 's#^https?://([^/:]+).*#\1#')"
  for _ in $(seq 1 20); do
    if curl -fsS -m 3 --resolve "$host:$port:127.0.0.1" "$url/api/v1/stats" \
         -H "Authorization: Bearer $tok" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

# ---- panel -----------------------------------------------------------------
install_panel() {
  ask DOMAIN "Panel domain (e.g. panel.example.com)"
  valid_domain "$DOMAIN" || die "invalid domain: $DOMAIN"
  ask EMAIL "ACME email"
  install_pkgs curl python3 openssl tar
  fetch_source
  if ! command -v crontab >/dev/null; then   # acme.sh needs cron for auto-renewal
    if command -v apt-get >/dev/null; then install_pkgs cron; else install_pkgs cronie; fi
    systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true
  fi
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || die "python >= 3.8 required"
  setup_cloudflare "$DOMAIN"

  # acme.sh with Cloudflare DNS-01
  if [ ! -x "$ACME_HOME/acme.sh" ]; then
    info "installing acme.sh"
    curl -fsSL https://get.acme.sh | sh -s email="$EMAIL" >/dev/null
  fi
  local zid; zid="$(cf zone "$DOMAIN")"
  info "issuing certificate for $DOMAIN (DNS-01, Let's Encrypt)"
  local rc=0
  CF_Token="$CF_TOKEN" CF_Zone_ID="$zid" "$ACME_HOME/acme.sh" --issue --dns dns_cf -d "$DOMAIN" \
    --server letsencrypt --keylength ec-256 || rc=$?
  [ $rc -eq 0 ] || [ $rc -eq 2 ] || die "certificate issuance failed (acme.sh exit $rc)"   # 2 = still valid, skipped

  id "$PANEL_USER" >/dev/null 2>&1 || useradd --system --home-dir "$PANEL_DIR" --shell /usr/sbin/nologin "$PANEL_USER"
  mkdir -p "$PANEL_DIR/data" "$PANEL_DIR/certs"
  copy_panel_code

  "$ACME_HOME/acme.sh" --install-cert -d "$DOMAIN" --ecc \
    --key-file "$PANEL_DIR/certs/key.pem" --fullchain-file "$PANEL_DIR/certs/fullchain.pem" \
    --reloadcmd "chown root:$PANEL_USER $PANEL_DIR/certs/*.pem && chmod 640 $PANEL_DIR/certs/*.pem && systemctl restart hy2mgr" \
    >/dev/null || true
  chown root:"$PANEL_USER" "$PANEL_DIR"/certs/*.pem && chmod 640 "$PANEL_DIR"/certs/*.pem

  # keep existing secrets on re-install
  local env="$PANEL_DIR/.env" old_pass="" old_tok=""
  if [ -f "$env" ]; then
    old_pass="$(sed -n 's/^HY2M_ADMIN_PASS=//p' "$env")"
    old_tok="$(sed -n 's/^HY2M_API_TOKEN=//p' "$env")"
  fi
  ADMIN_PASS="${ADMIN_PASS:-${old_pass:-$(rand 16)}}"
  API_TOKEN="${old_tok:-$(rand 40)}"
  local url="https://$DOMAIN"; [ "$PANEL_PORT" = 443 ] || url="$url:$PANEL_PORT"
  PANEL_URL="$url"
  umask 077
  cat > "$env" <<EOF
HY2M_HOST=0.0.0.0
HY2M_PORT=$PANEL_PORT
HY2M_DB=$PANEL_DIR/data/hy2mgr.db
HY2M_ADMIN_USER=$ADMIN_USER
HY2M_ADMIN_PASS=$ADMIN_PASS
HY2M_API_TOKEN=$API_TOKEN
HY2M_PUBLIC_URL=$url
HY2M_SYNC_INTERVAL=60
HY2M_TLS_CERT=$PANEL_DIR/certs/fullchain.pem
HY2M_TLS_KEY=$PANEL_DIR/certs/key.pem
EOF
  umask 022
  chown root:"$PANEL_USER" "$env"; chmod 640 "$env"
  chown -R "$PANEL_USER":"$PANEL_USER" "$PANEL_DIR/data"

  write_panel_unit
  systemctl daemon-reload
  systemctl enable hy2mgr >/dev/null 2>&1
  systemctl restart hy2mgr
  open_port "$PANEL_PORT" tcp

  info "waiting for panel"
  wait_panel || die "panel did not start; see: journalctl -u hy2mgr -n 50"
  PANEL_SUMMARY="
  面板地址:   $url
  管理员:     $ADMIN_USER / $ADMIN_PASS
  API Token:  $API_TOKEN
  配置文件:   $PANEL_DIR/.env
  证书:       acme.sh 自动续期 (crontab -l 查看)"
}

# ---- node ------------------------------------------------------------------
hy_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64;;
    aarch64|arm64) echo arm64;;
    armv7*|armv6*) echo arm;;
    i386|i686) echo 386;;
    s390x) echo s390x;;
    riscv64) echo riscv64;;
    *) die "unsupported arch $(uname -m)";;
  esac
}

install_hysteria_bin() {
  local arch url; arch="$(hy_arch)"
  if [ "$HY_VERSION" = latest ]; then
    url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-$arch"
  else
    url="https://github.com/apernet/hysteria/releases/download/app/$HY_VERSION/hysteria-linux-$arch"
  fi
  info "downloading hysteria ($HY_VERSION, $arch)"
  curl -fsSL -o "$HY_BIN.new" "$url" || die "download failed: $url"
  chmod +x "$HY_BIN.new"
  "$HY_BIN.new" version >/dev/null || die "downloaded hysteria binary does not run"
  mv -f "$HY_BIN.new" "$HY_BIN"
}

# panel_api METHOD PATH [JSON]  -> response body on stdout
panel_api() {
  local args=(-fsS -m 15 -X "$1" "$PANEL_URL/api/v1$2" -H "Authorization: Bearer $API_TOKEN")
  [ -n "${3:-}" ] && args+=(-H "Content-Type: application/json" -d "$3")
  [ -n "${PANEL_RESOLVE:-}" ] && args+=(--resolve "$PANEL_RESOLVE")
  curl "${args[@]}"
}

install_node() {
  ask DOMAIN "Node domain (e.g. hk.example.com)"
  valid_domain "$DOMAIN" || die "invalid domain: $DOMAIN"
  ask EMAIL "ACME email"
  ask PANEL_URL "Panel URL (e.g. https://panel.example.com)"
  PANEL_URL="${PANEL_URL%/}"
  ask API_TOKEN "Panel API token" secret
  NODE_NAME="${NODE_NAME:-$DOMAIN}"
  install_pkgs curl python3
  command -v iptables >/dev/null || install_pkgs iptables || warn "iptables not available: port hopping will not work"
  setup_cloudflare "$DOMAIN"

  info "checking panel API"
  panel_api GET /stats >/dev/null || die "cannot reach panel API at $PANEL_URL (check URL / API token)"

  install_hysteria_bin
  id "$HY_USER" >/dev/null 2>&1 || useradd --system --home-dir "$HY_DATA_DIR" --shell /usr/sbin/nologin "$HY_USER"
  mkdir -p "$HY_CONF_DIR" "$HY_DATA_DIR/acme"
  chown -R "$HY_USER":"$HY_USER" "$HY_DATA_DIR"

  # keep stats secret on re-install
  local conf="$HY_CONF_DIR/config.yaml" secret="" obfs_pw="" port_spec="$NODE_PORT"
  if [ -f "$conf" ]; then secret="$(sed -n 's/^  secret: //p' "$conf" | head -1)"; fi
  secret="${secret:-$(rand 32)}"

  # An already registered node keeps the port / obfs set in the panel unless overridden here.
  local existing="" cur_port="" cur_obfs="" cur_hop=""
  IFS=$'\x1f' read -r existing cur_port cur_obfs cur_hop < <(panel_api GET /nodes | ADDR="$DOMAIN" python3 -c '
import json, os, sys
for n in json.load(sys.stdin)["items"]:
    if n["address"] == os.environ["ADDR"]:
        print("\x1f".join(str(n.get(k, "")) for k in ("id", "port", "obfs_password", "hop_ports"))); break') || true
  if [ -n "$existing" ]; then
    [ "$PORT_SET" = 1 ] || port_spec="$cur_port"
    [ "$OBFS" = 0 ] || obfs_pw="$cur_obfs"
    [ "$HOP_SET" = 1 ] || HOP="$cur_hop"
  fi
  if [ "$OBFS" = 1 ] && [ -z "$obfs_pw" ]; then obfs_pw="$(rand 24)"; fi
  NODE_PORT="${port_spec%%[-,]*}"   # hysteria listens on the first port of a range / list

  # Same machine as the panel -> stats API stays on localhost.
  local stats_listen stats_url local_panel=0
  if [ "$MODE" = all ]; then
    local_panel=1
    stats_listen="127.0.0.1:$STATS_PORT"; stats_url="http://127.0.0.1:$STATS_PORT"
  else
    stats_listen=":$STATS_PORT"; stats_url="http://$DOMAIN:$STATS_PORT"
  fi

  # register (or update) the node on the panel
  info "registering node on panel"
  local body node_json
  body="$(NAME="$NODE_NAME" ADDR="$DOMAIN" PORT="$port_spec" OBFS="$obfs_pw" HOP="$HOP" URL="$stats_url" SEC="$secret" python3 -c '
import json, os
print(json.dumps({"name": os.environ["NAME"], "address": os.environ["ADDR"], "port": os.environ["PORT"],
                  "sni": os.environ["ADDR"], "insecure": False, "obfs_password": os.environ["OBFS"],
                  "hop_ports": os.environ["HOP"],
                  "api_url": os.environ["URL"], "api_secret": os.environ["SEC"], "enabled": True}))')"
  if [ -n "$existing" ]; then
    node_json="$(panel_api PATCH "/nodes/$existing" "$body")" || die "panel rejected the node settings (check --port / --hop)"
  else
    node_json="$(panel_api POST /nodes "$body")" || die "panel rejected the node settings (check --port / --hop)"
  fi
  local auth_token
  auth_token="$(echo "$node_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["auth_token"])')"

  info "writing $conf"
  umask 027
  {
    echo "listen: :$NODE_PORT"
    echo
    echo "acme:"
    echo "  domains:"
    echo "    - $DOMAIN"
    echo "  email: $EMAIL"
    echo "  ca: letsencrypt"
    echo "  dir: $HY_DATA_DIR/acme"
    echo "  type: dns"
    echo "  dns:"
    echo "    name: cloudflare"
    echo "    config:"
    echo "      cloudflare_api_token: $CF_TOKEN"
    echo
    if [ -n "$obfs_pw" ]; then
      echo "obfs:"
      echo "  type: salamander"
      echo "  salamander:"
      echo "    password: $(V="$obfs_pw" python3 -c 'import json,os; print(json.dumps(os.environ["V"]))')"
      echo
    fi
    echo "auth:"
    echo "  type: http"
    echo "  http:"
    echo "    url: $PANEL_URL/hy2/auth/$auth_token"
    echo "    insecure: false"
    echo
    echo "trafficStats:"
    echo "  listen: $stats_listen"
    echo "  secret: $secret"
    echo
    echo "masquerade:"
    echo "  type: proxy"
    echo "  proxy:"
    echo "    url: https://www.bing.com/"
    echo "    rewriteHost: true"
  } > "$conf"
  umask 022
  chown root:"$HY_USER" "$conf"; chmod 640 "$conf"

  # bigger UDP buffers for QUIC
  cat > /etc/sysctl.d/99-hysteria.conf <<'EOF'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
  sysctl -q -p /etc/sysctl.d/99-hysteria.conf || true

  write_hysteria_unit
  install_node_agent
  systemctl daemon-reload
  systemctl enable hysteria-server >/dev/null 2>&1
  local started; started="$(date +%s)"
  systemctl restart hysteria-server
  systemctl enable --now hy2mgr-node-sync.timer >/dev/null 2>&1

  open_port "$NODE_PORT" udp
  if [ $local_panel = 0 ]; then
    local panel_host panel_ip
    panel_host="$(echo "$PANEL_URL" | sed -E 's#^https?://([^/:]+).*#\1#')"
    panel_ip="$(getent ahostsv4 "$panel_host" | awk 'NR==1{print $1}')"
    if [ -n "$panel_ip" ]; then open_port "$STATS_PORT" tcp "$panel_ip"; fi
  fi

  info "waiting for hysteria to obtain the certificate (DNS-01 can take ~1 min)"
  if ! wait_hysteria "$started"; then
    journalctl -u hysteria-server -n 20 --no-pager || true
    die "hysteria did not start; see: journalctl -u hysteria-server -n 50"
  fi

  # apply port hopping rules (and report the state to the panel) right away
  systemctl start hy2mgr-node-sync >/dev/null 2>&1 || warn "hy2mgr-node-sync failed; see: journalctl -u hy2mgr-node-sync"

  info "testing panel -> node stats API"
  local node_id; node_id="$(echo "$node_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  if ! panel_api POST "/nodes/$node_id/sync" >/dev/null 2>&1; then
    if [ $local_panel = 1 ]; then
      warn "panel cannot reach $stats_url yet; check: journalctl -u hysteria-server -n 50"
    else
      warn "panel cannot reach $stats_url yet. Allow TCP $STATS_PORT from the panel server in your firewall / security group."
    fi
  fi

  NODE_SUMMARY="
  节点:       $NODE_NAME ($DOMAIN:$NODE_PORT/udp${HOP:+，端口跳跃 $HOP})
  配置文件:   $conf  (面板修改端口/混淆后由 hy2mgr-node-sync 每分钟自动同步)
  证书:       hysteria 内置 ACME (Cloudflare DNS-01)，自动续期
  统计 API:   $stats_url  (仅需对面板开放)
  日志:       journalctl -u hysteria-server -f"
  if [ $local_panel = 0 ]; then
    NODE_SUMMARY="$NODE_SUMMARY
  ${c_ylw}注意: 云服务器安全组需放行 UDP $NODE_PORT${HOP:+ 和 UDP $HOP}，以及来自面板的 TCP $STATS_PORT${c_off}"
  fi
}

write_hysteria_unit() {
  cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria2 Server
After=network-online.target
Wants=network-online.target

[Service]
User=$HY_USER
Group=$HY_USER
WorkingDirectory=$HY_DATA_DIR
Environment=HYSTERIA_LOG_LEVEL=info
ExecStart=$HY_BIN server -c $HY_CONF_DIR/config.yaml
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
LimitNOFILE=1048576
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

# wait_hysteria SINCE_EPOCH: wait until hysteria logs "server up and running" after SINCE_EPOCH
wait_hysteria() {
  for _ in $(seq 1 90); do
    systemctl is-active -q hysteria-server || return 1
    if journalctl -u hysteria-server --since "@$1" --no-pager 2>/dev/null | grep -q "server up and running"; then return 0; fi
    sleep 2
  done
  return 1
}

latest_hysteria_version() {
  curl -fsSLI -m 20 -o /dev/null -w '%{url_effective}' https://github.com/apernet/hysteria/releases/latest 2>/dev/null \
    | sed -n 's#.*/tag/app/\(v[0-9][0-9.]*\)$#\1#p'
}

# Agent that pulls port / obfs settings from the panel and applies them to config.yaml.
install_node_agent() {
  cat > /usr/local/bin/hy2mgr-node-sync <<'AGENT'
#!/usr/bin/env python3
"""Pull this node's port / obfs / port-hopping settings from the hy2mgr panel and apply
them: port and obfs go into the hysteria config (rolled back if hysteria fails to start),
port hopping is an iptables REDIRECT of a UDP port range to the listen port. Runs every
minute, so the NAT rules are restored after a reboot."""
import json, os, re, shutil, subprocess, sys, time, urllib.parse, urllib.request

CONF = os.environ.get("HY_CONF", "/etc/hysteria/config.yaml")
SERVICE = "hysteria-server"
# Settings that failed to start are remembered so we don't restart-loop every minute.
FAILED = os.environ.get("HY_SYNC_FAILED", "/run/hy2mgr-node-sync.failed")
CHAIN = "HY2MGR_HOP"
OBFS_RE = re.compile(r"^obfs:\n(?:[ \t]+.*\n)*\n?", re.M)


def current(text):
    m = re.search(r"^listen:\s*\S*?:?(\d+)\s*$", text, re.M)
    port = m.group(1) if m else ""
    obfs = ""
    b = OBFS_RE.search(text)
    if b:
        pm = re.search(r"^\s+password:\s*(.+?)\s*$", b.group(0), re.M)
        if pm:
            v = pm.group(1)
            obfs = json.loads(v) if v.startswith('"') else v.strip("'")
    return port, obfs


def fetch(base, token, port, obfs, hop):
    q = urllib.parse.urlencode({"port": port, "obfs": obfs, "hop": hop})
    with urllib.request.urlopen("%s/hy2/node/%s/config?%s" % (base, token, q), timeout=15) as r:
        return json.load(r)


def open_firewall(port):
    def ok(cmd):
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if shutil.which("ufw") and b"Status: active" in subprocess.run(["ufw", "status"], stdout=subprocess.PIPE).stdout:
        ok(["ufw", "allow", "%s/udp" % port])
    elif shutil.which("firewall-cmd") and ok(["firewall-cmd", "--state"]):
        ok(["firewall-cmd", "--permanent", "--add-port=%s/udp" % port]) and ok(["firewall-cmd", "--reload"])


def ipt(tool, *args):
    return subprocess.run([tool, "-w", "-t", "nat"] + list(args), stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE)


def hop_rules_ok(listen, spec):
    """True if the IPv4 NAT chain already redirects exactly `spec` to `listen`."""
    r = ipt("iptables", "-S", CHAIN)
    rules = r.stdout.decode() if r.returncode == 0 else ""
    if not spec:
        return "-A " not in rules
    sig = "hy2mgr:%s:%s" % (listen, spec)
    return re.search(re.escape(sig) + r'(?=["\s]|$)', rules) is not None and \
        ipt("iptables", "-C", "PREROUTING", "-j", CHAIN).returncode == 0


def ensure_hop(listen, spec):
    """Redirect UDP ports in `spec` (e.g. 20000-30000,40000-41000) to `listen`.
    Returns the spec now in effect ("" if disabled or not applicable)."""
    if not shutil.which("iptables"):
        if spec:
            print("iptables not found, port hopping not applied", file=sys.stderr)
        return ""
    if hop_rules_ok(listen, spec):
        return spec
    sig = "hy2mgr:%s:%s" % (listen, spec)
    for tool in ("iptables", "ip6tables"):
        if not shutil.which(tool):
            continue
        ipt(tool, "-N", CHAIN)
        ipt(tool, "-F", CHAIN)
        errs = []
        for part in spec.split(",") if spec else []:
            r = ipt(tool, "-A", CHAIN, "-p", "udp", "--dport", part.replace("-", ":"),
                    "-m", "comment", "--comment", sig, "-j", "REDIRECT", "--to-ports", str(listen))
            if r.returncode:
                errs.append(r.stderr.decode().strip())
        if spec and ipt(tool, "-C", "PREROUTING", "-j", CHAIN).returncode:
            r = ipt(tool, "-I", "PREROUTING", "-j", CHAIN)
            if r.returncode:
                errs.append(r.stderr.decode().strip())
        if errs and tool == "iptables":  # IPv6 NAT is best effort
            ipt(tool, "-F", CHAIN)
            print("port hopping rules failed: %s" % "; ".join(errs), file=sys.stderr)
            return ""
    print("port hopping: udp %s -> %s" % (spec, listen) if spec else "port hopping disabled")
    return spec


def write(text, ref):
    st = os.stat(ref)
    tmp = ref + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.chown(tmp, st.st_uid, st.st_gid)
    os.chmod(tmp, st.st_mode & 0o7777)
    os.replace(tmp, ref)


def restart_ok():
    subprocess.run(["systemctl", "restart", SERVICE])
    time.sleep(5)
    return subprocess.run(["systemctl", "is-active", "-q", SERVICE]).returncode == 0


def main():
    text = open(CONF).read()
    m = re.search(r"^\s+url:\s*(\S+)/hy2/auth/(\S+?)\s*$", text, re.M)
    if not m:
        sys.exit("hy2mgr auth url not found in " + CONF)
    base, token = m.group(1), m.group(2)
    port, obfs = current(text)
    hop = spec_if_ok(port)
    before = (port, obfs, hop)
    want = fetch(base, token, port, obfs, hop)
    new_port, new_obfs = str(want["listen_port"]), want.get("obfs_password") or ""
    new_hop = want.get("hop_ports") or ""
    error = None

    if (new_port, new_obfs) != (port, obfs) and not failed_before(new_port, new_obfs):
        new = re.sub(r"^listen:.*$", "listen: :" + new_port, text, count=1, flags=re.M)
        new = OBFS_RE.sub("", new)
        if new_obfs:
            block = "obfs:\n  type: salamander\n  salamander:\n    password: %s\n\n" % json.dumps(new_obfs)
            new = re.sub(r"^auth:", lambda _: block + "auth:", new, count=1, flags=re.M)
        write(new, CONF)
        if new_port != port:
            open_firewall(new_port)
        if restart_ok():
            print("applied: port %s -> %s, obfs %s" % (port, new_port, "on" if new_obfs else "off"))
            port, obfs = new_port, new_obfs
        else:
            write(text, CONF)
            restart_ok()
            with open(FAILED, "w") as f:
                json.dump([new_port, new_obfs], f)
            error = ("hysteria failed to start with the new settings (port %s); rolled back, "
                     "fix them in the panel (see journalctl -u %s)" % (new_port, SERVICE))

    # Port hopping always targets the listen port actually in use.
    applied_hop = ensure_hop(port, new_hop)
    if (port, obfs, applied_hop) != before:
        fetch(base, token, port, obfs, applied_hop)  # report the applied state
    if error:
        sys.exit(error)


def spec_if_ok(port):
    """The hop spec currently in effect for `port`, read back from the NAT chain."""
    if not shutil.which("iptables"):
        return ""
    r = ipt("iptables", "-S", CHAIN)
    m = re.search(r"hy2mgr:%s:([0-9,-]+)" % re.escape(port), r.stdout.decode() if r.returncode == 0 else "")
    return m.group(1) if m and hop_rules_ok(port, m.group(1)) else ""


def failed_before(new_port, new_obfs):
    try:
        with open(FAILED) as f:
            return json.load(f) == [new_port, new_obfs]
    except (OSError, ValueError):
        return False


if __name__ == "__main__":
    main()
AGENT
  chmod 755 /usr/local/bin/hy2mgr-node-sync

  cat > /etc/systemd/system/hy2mgr-node-sync.service <<'EOF'
[Unit]
Description=Apply hy2mgr panel node settings to hysteria
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hy2mgr-node-sync
EOF
  cat > /etc/systemd/system/hy2mgr-node-sync.timer <<'EOF'
[Unit]
Description=Poll hy2mgr panel for node settings

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
}

# ---- update ----------------------------------------------------------------
update_panel() {
  local cur; cur="$(cat "$PANEL_DIR/VERSION" 2>/dev/null || true)"
  if [ -n "$SRC_SHA" ] && [ "$cur" = "$SRC_SHA" ] && [ "$FORCE" != 1 ]; then
    info "panel is up to date (${SRC_SHA:0:7})"
    UPDATE_SUMMARY="$UPDATE_SUMMARY
  面板:       已是最新 ${SRC_SHA:0:7}"
    return
  fi
  info "updating panel ${cur:0:7} -> ${SRC_SHA:-latest}"

  # online backup of the database (safe while the panel is running)
  local db bak_dir bak
  db="$(env_get HY2M_DB)"; db="${db:-$PANEL_DIR/data/hy2mgr.db}"
  bak_dir="$PANEL_DIR/data/backups"; bak="$bak_dir/hy2mgr-$(date +%Y%m%d-%H%M%S).db"
  if [ -f "$db" ]; then
    mkdir -p "$bak_dir"
    python3 -c 'import sqlite3,sys; s=sqlite3.connect(sys.argv[1]); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close()' "$db" "$bak" \
      || die "database backup failed"
    chown -R "$PANEL_USER":"$PANEL_USER" "$bak_dir"
    # keep the 10 newest backups
    find "$bak_dir" -name 'hy2mgr-*.db' | sort -r | tail -n +11 | xargs -r rm -f
    info "database backed up to $bak"
  fi

  rm -rf "$PANEL_DIR/hy2mgr.bak"
  cp -a "$PANEL_DIR/hy2mgr" "$PANEL_DIR/hy2mgr.bak"
  [ -f "$PANEL_DIR/VERSION" ] && cp -a "$PANEL_DIR/VERSION" "$PANEL_DIR/VERSION.bak"
  copy_panel_code
  write_panel_unit
  systemctl daemon-reload
  systemctl restart hy2mgr
  if wait_panel; then
    rm -rf "$PANEL_DIR/hy2mgr.bak" "$PANEL_DIR/VERSION.bak"
    UPDATE_SUMMARY="$UPDATE_SUMMARY
  面板:       ${cur:0:7} -> ${SRC_SHA:0:7}  (数据库备份: $bak)"
  else
    warn "new panel version failed to start, rolling back"
    journalctl -u hy2mgr -n 20 --no-pager 2>/dev/null || true
    rm -rf "$PANEL_DIR/hy2mgr"; mv "$PANEL_DIR/hy2mgr.bak" "$PANEL_DIR/hy2mgr"
    if [ -f "$PANEL_DIR/VERSION.bak" ]; then mv -f "$PANEL_DIR/VERSION.bak" "$PANEL_DIR/VERSION"; else rm -f "$PANEL_DIR/VERSION"; fi
    systemctl restart hy2mgr
    if wait_panel; then
      die "update failed; rolled back to ${cur:0:7} (running). Database backup: $bak"
    fi
    die "update failed and the old version did not start either; see journalctl -u hy2mgr. Database backup: $bak"
  fi
}

update_node() {
  command -v iptables >/dev/null || install_pkgs iptables || warn "iptables not available: port hopping will not work"
  info "updating node sync agent"
  install_node_agent
  write_hysteria_unit
  systemctl daemon-reload
  systemctl enable --now hy2mgr-node-sync.timer >/dev/null 2>&1
  local line="  节点同步:   hy2mgr-node-sync 已更新"

  if [ "$UPDATE_HY" = 1 ]; then
    local cur want
    cur="$("$HY_BIN" version 2>/dev/null | sed -n 's/^Version:[[:space:]]*//p')"
    want="$HY_VERSION"; [ "$want" = latest ] && want="$(latest_hysteria_version)"
    if [ -z "$want" ]; then
      warn "cannot determine the latest hysteria version, skipping hysteria upgrade"
    elif [ "$cur" = "$want" ]; then
      info "hysteria is up to date ($cur)"
      line="$line
  hysteria:   已是最新 $cur"
    else
      info "upgrading hysteria $cur -> $want"
      cp -a "$HY_BIN" "$HY_BIN.bak"
      HY_VERSION="$want" install_hysteria_bin
      local started; started="$(date +%s)"
      systemctl restart hysteria-server
      if wait_hysteria "$started"; then
        rm -f "$HY_BIN.bak"
        line="$line
  hysteria:   $cur -> $want"
      else
        warn "hysteria $want failed to start, rolling back to $cur"
        journalctl -u hysteria-server -n 20 --no-pager 2>/dev/null || true
        mv -f "$HY_BIN.bak" "$HY_BIN"
        systemctl restart hysteria-server
        line="$line
  hysteria:   升级到 $want 失败，已回滚到 $cur"
      fi
    fi
  fi
  systemctl start hy2mgr-node-sync >/dev/null 2>&1 || true
  UPDATE_SUMMARY="$UPDATE_SUMMARY
$line"
}

update_all() {
  local panel=0 node=0
  [ -f /etc/systemd/system/hy2mgr.service ] && [ -d "$PANEL_DIR/hy2mgr" ] && panel=1
  [ -f /etc/systemd/system/hysteria-server.service ] && [ -f "$HY_CONF_DIR/config.yaml" ] && node=1
  [ $panel = 1 ] || [ $node = 1 ] || die "nothing to update: neither the panel nor a node was installed by install.sh"
  install_pkgs curl python3 tar
  if [ $panel = 1 ]; then fetch_source; update_panel; fi
  if [ $node = 1 ]; then update_node; fi
}

uninstall() {
  case "${1:-}" in
    panel)
      systemctl disable --now hy2mgr 2>/dev/null || true
      rm -f /etc/systemd/system/hy2mgr.service
      local d; d="$(sed -n 's#^HY2M_PUBLIC_URL=https://\([^:/]*\).*#\1#p' "$PANEL_DIR/.env" 2>/dev/null || true)"
      if [ -n "$d" ] && [ -x "$ACME_HOME/acme.sh" ]; then "$ACME_HOME/acme.sh" --remove -d "$d" --ecc >/dev/null 2>&1 || true; fi
      rm -rf "$PANEL_DIR/hy2mgr" "$PANEL_DIR/certs" "$PANEL_DIR/.env"
      info "panel removed. Database kept at $PANEL_DIR/data (delete it manually if not needed)";;
    node)
      systemctl disable --now hy2mgr-node-sync.timer hysteria-server 2>/dev/null || true
      for t in iptables ip6tables; do   # port hopping NAT rules
        command -v "$t" >/dev/null || continue
        "$t" -w -t nat -D PREROUTING -j HY2MGR_HOP 2>/dev/null || true
        "$t" -w -t nat -F HY2MGR_HOP 2>/dev/null || true
        "$t" -w -t nat -X HY2MGR_HOP 2>/dev/null || true
      done
      rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hy2mgr-node-sync.* \
            /usr/local/bin/hy2mgr-node-sync "$HY_BIN" /etc/sysctl.d/99-hysteria.conf
      rm -rf "$HY_CONF_DIR" "$HY_DATA_DIR"
      info "hysteria removed. Delete the node in the panel as well.";;
    *) die "usage: install.sh uninstall panel|node";;
  esac
  systemctl daemon-reload
}

# ---- main ------------------------------------------------------------------
PANEL_SUMMARY=""; NODE_SUMMARY=""; UPDATE_SUMMARY=""; SRC_DIR=""; SRC_SHA=""
case "$MODE" in
  panel) need_root; install_panel;;
  node)  need_root; install_node;;
  all)
    need_root
    ask DOMAIN "Panel domain (e.g. panel.example.com)"
    if [ -z "$NODE_DOMAIN" ] && [ -t 0 ]; then read -rp "Node domain (Enter = same as panel): " NODE_DOMAIN; fi
    NODE_DOMAIN="${NODE_DOMAIN:-$DOMAIN}"
    valid_domain "$NODE_DOMAIN" || die "invalid domain: $NODE_DOMAIN"
    install_panel
    PANEL_DOMAIN="$DOMAIN"; DOMAIN="$NODE_DOMAIN"
    # talk to the local panel directly, independent of DNS propagation
    PANEL_RESOLVE="$PANEL_DOMAIN:$PANEL_PORT:127.0.0.1"
    [ "$NODE_PORT" = "$PANEL_PORT" ] && info "panel uses TCP $PANEL_PORT, hysteria uses UDP $NODE_PORT — no conflict"
    install_node;;
  update)
    need_root; update_all
    echo; info "更新完成"; echo "$UPDATE_SUMMARY"; echo; exit 0;;
  uninstall) need_root; uninstall "$UNINSTALL_WHAT"; exit 0;;
  ""|-h|--help) usage; exit 0;;
  *) usage; exit 1;;
esac

echo
info "安装完成"
[ -n "$PANEL_SUMMARY" ] && echo "$PANEL_SUMMARY"
[ -n "$NODE_SUMMARY" ] && echo "$NODE_SUMMARY"
echo
