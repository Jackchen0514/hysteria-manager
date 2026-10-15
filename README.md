# Hysteria2 Manager

Hysteria2 的多节点用户管理平台：Web 管理面板 + REST API，支持用户到期时间、流量限额、流量重置、自动月度重置、订阅链接。

- **零依赖**：只用 Python 3.8+ 标准库（sqlite3 + http.server），拷过去就能跑
- **对接方式**：使用 Hysteria2 官方的 [HTTP 认证](https://v2.hysteria.network/docs/advanced/Full-Server-Config/#http) 和 [流量统计 API](https://v2.hysteria.network/docs/advanced/Traffic-Stats-API/)，节点端不需要装额外程序

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Jackchen0514/hysteria-manager/main/install.sh) all
```

以 root 运行，按提示输入面板域名、节点域名、Cloudflare API Token 和邮箱即可：自动配置 DNS、申请 Let's Encrypt 证书（DNS-01）、安装面板和 Hysteria2 节点。

只装面板用 `panel`，给其他服务器加节点用 `node`，查看全部参数用 `--help`，详见下方[一键安装说明](#一键安装cloudflare-域名--lets-encryptdns-01-验证)。

## 一键更新

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Jackchen0514/hysteria-manager/main/update.sh)
```

在面板服务器和每台节点服务器上分别执行（同机部署执行一次即可），自动识别本机装了什么：

- **面板**：更新到仓库最新提交；先在线备份数据库到 `/opt/hy2mgr/data/backups/`（保留最近 10 份），新版本启动失败自动回滚。已是最新则跳过
- **节点**：更新节点同步程序 `hy2mgr-node-sync`（旧版安装的节点会补装），并把 hysteria 升级到最新版；hysteria 新版本启动失败自动回滚
- 用户、配置、证书、密码都不变，不需要 Cloudflare Token

可选参数：`--no-hysteria` 不升级 hysteria，`--hy-version v2.6.1` 指定 hysteria 版本，`--force` 强制重装面板代码。升级 hysteria 会重启节点，在线用户会断开几秒后自动重连。

## 工作原理

```
           ① 客户端连接 (auth=用户密码)
 Client ───────────────────────────▶ Hysteria2 节点
                                       │  ② POST /hy2/auth/<节点token>  {"auth": "..."}
                                       ▼
                                   hy2mgr 面板 ── 校验：用户存在 / 已启用 / 未过期 / 未超额
                                       │  ③ 每 N 秒 GET /traffic?clear=1 累加流量
                                       │     GET /online 查在线用户，不合规的 POST /kick 踢下线
```

- 认证在**连接时**校验，所以过期、超额、禁用的用户无法建立新连接
- 已连接的用户会在下一次同步（`HY2M_SYNC_INTERVAL`）时被踢掉；在面板或 API 里禁用、删除、改密码，或因缩短时间、减少流量导致用户不再合规时，**立即**踢下线
- 流量统计：`upload` = 客户端上传，`download` = 客户端下载，已用流量 = 两者之和

## 快速开始

```bash
HY2M_ADMIN_PASS=your-pass HY2M_PUBLIC_URL=http://你的面板IP:8080 python3 -m hy2mgr
```

打开 `http://IP:8080`，用 `admin / your-pass` 登录。不设置 `HY2M_ADMIN_PASS` 时首次启动会随机生成密码并打印在日志里。

### 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `HY2M_HOST` / `HY2M_PORT` | `0.0.0.0` / `8080` | 监听地址 |
| `HY2M_DB` | `data/hy2mgr.db` | SQLite 数据库路径 |
| `HY2M_ADMIN_USER` / `HY2M_ADMIN_PASS` | `admin` / 随机 | 管理员账号 |
| `HY2M_API_TOKEN` | 空 | 固定 API Token，供其他系统调用（建议 32 位以上随机串） |
| `HY2M_PUBLIC_URL` | 空 | 面板对外地址，用于生成订阅链接和节点回调地址 |
| `HY2M_SYNC_INTERVAL` | `60` | 流量同步 / 踢人间隔（秒） |
| `HY2M_SESSION_TTL` | `604800` | 登录 token 有效期（秒） |

### 一键安装（Cloudflare 域名 + Let's Encrypt，DNS-01 验证）

需要一个 Cloudflare API Token：Cloudflare 后台 → My Profile → API Tokens → Create Token，权限 **Zone · Zone · Read** + **Zone · DNS · Edit**。脚本会自动把域名的 A 记录指向本机（**仅 DNS，不开小黄云**，因为 Hysteria2 走 UDP，无法经过 CF 代理）。

可以直接在线执行（面板代码会自动下载），也可以 clone 仓库后执行 `bash install.sh ...`，参数相同：

```bash
# 面板 + 节点装在同一台机器（最简单）
bash <(curl -fsSL https://raw.githubusercontent.com/Jackchen0514/hysteria-manager/main/install.sh) all \
     --domain panel.example.com --node-domain hk.example.com --cf-token <CF_TOKEN> --email you@mail.com

# 在其他服务器上加节点，自动注册到面板
bash <(curl -fsSL https://raw.githubusercontent.com/Jackchen0514/hysteria-manager/main/install.sh) node \
     --domain jp.example.com --cf-token <CF_TOKEN> --email you@mail.com \
     --panel https://panel.example.com --api-token <面板 API Token> --name 日本 [--obfs]
```

在仓库目录内执行：

```bash
bash install.sh all --domain panel.example.com --node-domain hk.example.com \
     --cf-token <CF_TOKEN> --email you@mail.com

# 只装面板
bash install.sh panel --domain panel.example.com --cf-token <CF_TOKEN> --email you@mail.com

# 加节点
bash install.sh node --domain jp.example.com --cf-token <CF_TOKEN> --email you@mail.com \
     --panel https://panel.example.com --api-token <面板 API Token> --name 日本 [--obfs]

# 卸载
bash install.sh uninstall panel|node
```

- 面板证书：acme.sh + `dns_cf` 签发，cron 自动续期，续期后自动重启面板；面板直接以 HTTPS 运行（`HY2M_TLS_CERT` / `HY2M_TLS_KEY`）
- 节点证书：Hysteria2 内置 ACME（`type: dns`，`name: cloudflare`），自动续期，无需 acme.sh
- 面板占用 TCP 443，节点占用 UDP 443，可以在同一台机器共存
- 重复执行脚本不会改变管理员密码、API Token、统计密钥；同一域名的节点会更新而不是重复添加
- 云服务器安全组需放行：面板 TCP 端口、节点 UDP 端口、节点的 TCP 9999（仅允许面板 IP）
- 缺少的参数会交互式询问，`bash install.sh --help` 查看全部选项

### 手动部署

**systemd**

```bash
mkdir -p /opt/hy2mgr && cp -r hy2mgr /opt/hy2mgr/
cp deploy/env.example /opt/hy2mgr/.env && vi /opt/hy2mgr/.env
cp deploy/hy2mgr.service /etc/systemd/system/ && systemctl enable --now hy2mgr
```

**Docker**

```bash
docker build -t hy2mgr .
docker run -d --name hy2mgr -p 8080:8080 -v /opt/hy2mgr/data:/data \
  -e HY2M_ADMIN_PASS=xxx -e HY2M_API_TOKEN=xxx -e HY2M_PUBLIC_URL=https://panel.example.com hy2mgr
```

公网部署建议在前面挂一层 Nginx/Caddy 提供 HTTPS。

## 添加节点

1. 面板 → 节点 → 新建节点，填写连接地址、端口、统计 API 地址（`http://节点IP:9999`）和 API Secret
2. 点击「服务端配置」，把生成的配置写入节点的 `/etc/hysteria/config.yaml`，替换证书路径后重启 hysteria。关键部分：

```yaml
auth:
  type: http
  http:
    url: https://panel.example.com/hy2/auth/<节点token>   # 每个节点独立 token
trafficStats:
  listen: :9999
  secret: <API Secret>
```

3. 节点的 `9999` 端口只需对面板开放（防火墙限制来源 IP）。节点也必须能访问面板的回调地址。

### 在面板修改端口 / 混淆

用 `install.sh` 安装的节点带有同步程序 `hy2mgr-node-sync`（systemd timer，每分钟一次）：从面板拉取该节点的端口和混淆密码，与 `/etc/hysteria/config.yaml` 不一致时自动改写并重启 hysteria。

- 节点列表的「配置下发」一列显示状态：**已应用** / **待应用** / **未安装同步**（手动部署的节点需自己改 `config.yaml`）
- 新配置启动失败会自动回滚到旧配置，并且不会每分钟反复重试，直到面板里的设置再次修改
- 本机 ufw / firewalld 会自动放行新端口，**云服务器安全组需要自己放行**
- 填写端口范围（如 `20000-30000`）时 hysteria 只监听第一个端口，端口跳跃所需的 iptables 转发规则需自行配置
- 手动触发：`systemctl start hy2mgr-node-sync`，查看日志：`journalctl -u hy2mgr-node-sync`
- 重新执行 `install.sh` 会保留面板里设置的端口和混淆，除非显式传入 `--port` / `--obfs` / `--no-obfs`

## 订阅

每个用户有独立的订阅地址 `/sub/<token>`：

- 默认：base64 编码的 `hysteria2://` 链接列表（v2rayN、NekoBox、Shadowrocket 等）
- `?format=clash`：Clash Meta / Mihomo 配置（UA 中含 clash/mihomo/stash 时自动识别）
- `?format=raw`：未编码的链接列表

响应头带 `Subscription-Userinfo`，客户端能显示已用流量和到期时间。用户被禁用、过期或超额时订阅返回空列表。

---

## API 文档

所有 `/api/v1/*` 接口（除 login）需要请求头：

```
Authorization: Bearer <token>
```

token 为 `HY2M_API_TOKEN`，或调用 login 获得的会话 token。请求和响应都是 JSON。出错时返回 `{"error": "..."}` 和对应 HTTP 状态码（400 参数错误 / 401 未授权 / 404 不存在 / 409 冲突）。

### 用户对象

```json
{
  "id": 1,
  "username": "alice",
  "password": "xxxx",              // Hysteria2 连接密码
  "sub_token": "xxxx",
  "enabled": true,
  "expire_at": 1794638514,         // 到期时间 unix 秒，0 = 永不过期
  "traffic_limit": 107374182400,   // 流量限额 字节，0 = 不限
  "upload": 1833,
  "download": 20004889,
  "used": 20006722,
  "remaining": 107354175678,       // 不限流量时为 null
  "reset_day": 1,                  // 每月几号自动重置流量 (1-28)，0 = 不自动重置
  "traffic_multiplier": 1.0,       // 流量倍数：计入的流量 = 实际流量 × 倍数
  "last_reset_at": 1792046514,
  "status": "active",              // active | disabled | expired | overlimit
  "note": "",
  "subscription_url": "https://panel.example.com/sub/xxxx",
  "created_at": 1792046514,
  "updated_at": 1792046514
}
```

### 接口列表

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/v1/login` | `{"username","password"}` → `{"token","expire_at"}` |
| GET | `/api/v1/stats` | 概览统计 |
| POST | `/api/v1/sync` | 立即同步所有节点流量 |
| GET | `/api/v1/users?search=&status=&limit=50&offset=0` | 用户列表，`status`: active/disabled/expired/overlimit |
| POST | `/api/v1/users` | 创建用户 |
| GET | `/api/v1/users/{username}` | 用户详情（含 `links` 节点链接） |
| PATCH | `/api/v1/users/{username}` | 修改用户（只传需要改的字段） |
| DELETE | `/api/v1/users/{username}` | 删除用户并踢下线 |
| POST | `/api/v1/users/{username}/extend` | 续期 `{"days": 30}`，可为负数/小数，也可用 `seconds` |
| POST | `/api/v1/users/{username}/add-traffic` | 增加限额 `{"gb": 100}` 或 `{"bytes": n}`，负数为减少 |
| POST | `/api/v1/users/{username}/reset-traffic` | 已用流量清零 |
| POST | `/api/v1/users/{username}/regenerate` | 重新生成 `{"password": true, "sub": true}` |
| POST | `/api/v1/users/{username}/kick` | 在所有节点踢下线 |
| GET | `/api/v1/users/{username}/traffic?days=30` | 按天的流量历史 |
| GET | `/api/v1/nodes` | 节点列表 |
| POST | `/api/v1/nodes` | 创建节点 |
| GET / PATCH / DELETE | `/api/v1/nodes/{id}` | 节点详情 / 修改 / 删除；PATCH 传 `"regenerate_auth_token": true` 可重置回调 token |
| POST | `/api/v1/nodes/{id}/sync` | 同步单个节点 |
| GET | `/api/v1/nodes/{id}/config` | 生成该节点的 Hysteria2 服务端配置 |

### 创建 / 修改用户的字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `username` | string | 必填（创建），`[A-Za-z0-9_.@-]{1,64}`，修改时可改名 |
| `password` | string | 连接密码，≥6 位，创建时留空自动生成 |
| `traffic_limit` | int | 流量限额（字节），0 = 不限 |
| `traffic_limit_gb` | number | 同上，单位 GB（二选一） |
| `expire_at` | int | 到期时间（unix 秒），0 = 永不过期 |
| `expire_days` | number | 从现在起 N 天后到期（二选一），0 = 永不过期 |
| `reset_day` | int | 每月自动重置流量日，0-28 |
| `traffic_multiplier` | number | 流量倍数，默认 1.0，范围 0-100。计入的流量 = 实际流量 × 倍数（如 2 表示用 1GB 记 2GB，0 表示不计流量）；只影响之后同步的流量，已用流量不重新计算 |
| `enabled` | bool | 是否启用 |
| `upload` / `download` | int | 直接设置已用流量（字节） |
| `note` | string | 备注 |

### 节点字段

`name`（必填）、`address`（必填）、`port`（`443` / `20000-30000` / `443,8443`）、`sni`、`insecure`、`obfs_password`、`api_url`、`api_secret`、`enabled`、`sort`

### 示例

```bash
TOKEN=你的API_TOKEN
P=https://panel.example.com/api/v1

# 创建用户：100GB，30 天，每月 1 号重置流量
curl -X POST $P/users -H "Authorization: Bearer $TOKEN" \
  -d '{"username":"alice","traffic_limit_gb":100,"expire_days":30,"reset_day":1}'

# 续期 30 天（已过期则从现在开始算）
curl -X POST $P/users/alice/extend -H "Authorization: Bearer $TOKEN" -d '{"days":30}'

# 设置到期时间为指定时间
curl -X PATCH $P/users/alice -H "Authorization: Bearer $TOKEN" -d '{"expire_at":1798732800}'

# 修改流量限额为 200GB
curl -X PATCH $P/users/alice -H "Authorization: Bearer $TOKEN" -d '{"traffic_limit_gb":200}'

# 增加 50GB
curl -X POST $P/users/alice/add-traffic -H "Authorization: Bearer $TOKEN" -d '{"gb":50}'

# 重置已用流量
curl -X POST $P/users/alice/reset-traffic -H "Authorization: Bearer $TOKEN"

# 设置流量倍数为 1.5
curl -X PATCH $P/users/alice -H "Authorization: Bearer $TOKEN" -d '{"traffic_multiplier":1.5}'

# 禁用
curl -X PATCH $P/users/alice -H "Authorization: Bearer $TOKEN" -d '{"enabled":false}'
```

## 开发

```bash
python3 -m unittest discover -s tests -t .
```
