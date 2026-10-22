# 爬虫服务使用文档

一个 HTTP 服务，后面接一个 `lightpanda serve` 引擎进程。服务对引擎保持一组
CDP 连接（每条连接在引擎里有自己的工作线程和浏览器），每条连接同一时间只跑
一个抓取；所有连接都忙时，新请求按先来后到排队。

同一个端口还提供 MCP 接口（`/mcp`），让 agent 像用 Playwright 一样一步步操作页面
（打开、点击、填表、翻页……），见 [Agent 接入（MCP）](#agent-接入mcp)。

- 运行环境：Node ≥ 22，没有任何依赖。
- **没有鉴权**，服务和管理页都只应放在内网。
- 英文版（更细的实现说明和测量数据）：[README.md](README.md)。

目录：[部署](#部署) · [调用示例](#调用示例) · [请求与响应](#请求与响应) ·
[错误码](#错误码) · [超时与部分结果](#超时与部分结果) · [代理与代理池](#代理与代理池) ·
[Session](#session) · [Agent 接入（MCP）](#agent-接入mcp) · [翻页](#翻页) ·
[请求历史](#请求历史) · [管理页](#管理页) · [健康检查](#健康检查-get-health) ·
[停机](#停机) · [扩容建议](#扩容建议) · [测试](#测试)

## 部署

### Docker

一个镜像、一个容器：从本仓库编出的引擎加上本服务。在仓库根目录构建：

```bash
docker build -f service/Dockerfile -t lp-crawl .
docker run -d --name lp-crawl --restart unless-stopped \
  -p 8080:8080 -v crawl-data:/data -e POOL_SIZE=16 lp-crawl
curl -s localhost:8080/crawl -d '{"url":"https://example.com/","formats":["markdown","meta"]}'
```

- 构建要编译引擎（ReleaseFast），需要约 12 GB 内存；首次构建要下载 Rust、
  Zig、预编译 V8（约 130 MB，来自 GitHub）和依赖包。网络慢时用 Dockerfile 开头
  列出的国内镜像 build-arg，V8 和 Zig 包也可以用 `--build-context v8=… / zigpkg=…`
  从宿主机传入。需要 BuildKit（`docker buildx`）。只改了 `service/` 时，引擎层走
  缓存，重建只要几十秒。
- 容器里 `tini` 是 1 号进程，`entrypoint.sh` 启动两样东西：
  - `lightpanda serve`，只监听容器内的 `127.0.0.1:9222`，CDP 端口不对外。引擎退出后
    隔 `LP_RESTART_DELAY` 秒自动重启；正在跑的请求返回 `engine_disconnected`，排队中
    的请求会等它回来。引擎和这个重启循环用 `setsid` 放在自己的进程组里，`docker stop`
    的 SIGTERM 只到本服务；服务等在飞的抓取跑完后自己关引擎，见[停机](#停机)。
  - 本服务，监听 `0.0.0.0:8080`。服务退出则容器退出，由重启策略拉起。服务再启动
    `MCP_PROCS` 个 `lightpanda mcp` 进程（默认 2 个，只监听容器内的 `127.0.0.1:9300` 起），
    供 `/mcp` 使用，挂掉的自动重启。
- 以 `-` 开头的参数会追加到 `serve` 命令行（`docker run lp-crawl --log-level debug`），
  其他参数会代替服务执行（`docker run --rm lp-crawl lightpanda version`）。
- **不要**给引擎加 `--obey-robots`、`--web-bot-auth-*` 或 `--webmcp`：每一个都会把客户端
  暴露成机器人。MCP 进程带 `--no-webmcp` 启动，页面里没有 `navigator.modelContext` 等
  三个 Chrome 没有的名字（见 [Agent 接入](#伪装)）。

### `/data` 卷

`/data` 下有两样东西，挂一个卷才能在容器重建后保留：

| 目录 | 内容 |
|---|---|
| `/data/sessions` | session 的 cookie，每个 `session_id` 一个 JSON 文件 |
| `/data/history` | 请求历史，每天每个副本一个 JSONL 文件 |

### docker compose

```bash
docker compose -f service/compose.yaml up -d --build      # 单容器，CRAWL_PORT 选宿主端口
```

compose 把容器放在 Docker 默认的 `bridge` 网络（`network_mode: bridge`），在地址池
用完的 Docker 上也能启动，并把 `crawl-data` 卷挂到 `/data`。

多容器（推荐的扩容方式，见[扩容建议](#扩容建议)）用 `multi` profile 里的
`crawl-multi`：`CRAWL_REPLICAS` 个容器，每个 `POOL_SIZE=16`、限 21 个 CPU，各占
`CRAWL_PORTS` 里的一个宿主端口，前面自己放一个 HTTP 负载均衡：

```bash
CRAWL_REPLICAS=4 CRAWL_PORTS=8081-8084 \
  docker compose -f service/compose.yaml --profile multi up -d crawl-multi
```

### 环境变量

服务的配置：

| 变量 | 默认 | 说明 |
|---|---|---|
| `POOL_SIZE` | `4` | 同时进行的抓取数（连接槽位）。每容器建议 16，最多 32，见[扩容建议](#扩容建议) |
| `QUEUE_MAX` | `100` | 允许排队等槽位的请求数，超过返回 503 `queue_full` |
| `DEFAULT_TIMEOUT_MS` | `30000` | 请求不带 `timeout` 时用的超时 |
| `MAX_TIMEOUT_MS` | `120000` | 请求能要的最大 `timeout` |
| `PARTIAL_GRACE_MS` | `2000` | 超时后再花多久去取页面已有的 html/markdown，`0` 关闭 |
| `PROXY_POOL` | | 代理池的代理 URL，逗号、空格或换行分隔 |
| `PROXY_POOL_FILE` | | 代理列表文件，每行一个或多个，`#` 注释；与 `PROXY_POOL` 合并 |
| `PROXY_POOL_DEFAULT` | `false` | `true`：不带 `proxy` 字段的请求也走代理池 |
| `PROXY_MAX_FAILS` | `3` | 代理连续失败几次被剔除 |
| `PROXY_RETRY_AFTER_MS` | `60000` | 被剔除的代理多久后再试 |
| `PROXY_POOL_RETRIES` | `2` | `proxy: "pool"` 的请求在代理失败后再换几个代理重试，`0` 不重试 |
| `PROXY_PROBE` | | 所有代理都应能连上的 `host:port`（或 URL），用来区分「站点挂了」和「代理挂了」 |
| `SESSION_DIR` | 镜像里 `/data/sessions`；裸跑时无（只在内存） | session cookie 的存放目录 |
| `SESSION_TTL_MS` | `604800000`（7 天） | session 闲置这么久就删除（含文件），`0` 永不过期 |
| `SESSION_SWEEP_MS` | `600000` | 多久清理一次过期 session（启动时也清一次） |
| `HISTORY_DIR` | 镜像里 `/data/history`；裸跑时无（不记历史） | 请求历史目录，见[请求历史](#请求历史) |
| `HISTORY_RETENTION_DAYS` | `7` | 历史保留天数（含今天），更早的文件在启动时和每小时删除；`0` 全部保留 |
| `HISTORY_REPLICA` | 主机名（容器里就是容器 id） | 历史文件名里的副本标识，多副本共用一个卷时各写各的文件 |
| `HOST` / `PORT` | `0.0.0.0` / `8080` | 服务监听地址 |
| `MAX_BODY_BYTES` | `1048576` | 请求体上限 |
| `LP_CDP_URL` | `ws://127.0.0.1:9222/` | 引擎的 CDP 地址（镜像里自动设置） |
| `MCP_PROCS` | 镜像里 `2`；裸跑时 `0`（关闭 `/mcp`） | `lightpanda mcp` 进程数。一个进程同一时间只执行一个工具调用，这就是能同时有调用在执行的 agent 数，见[多会话](#多会话与并发) |
| `MCP_MAX_SESSIONS` | `32` | MCP 会话上限，满了 `initialize` 返回 503 |
| `MCP_SESSION_IDLE_MS` | `1800000`（30 分钟） | 会话多久没有调用就关闭，`0` 永不 |
| `MCP_CALL_TIMEOUT_MS` | `120000` | 单个 MCP 请求等引擎回答的上限，超过返回 504 |
| `SHUTDOWN_DRAIN_MS` | `5000` | 服务停止（SIGTERM/SIGINT）时，等在飞的 `/crawl` 跑完的上限；到时还没跑完的被放弃，见[停机](#停机) |
| `SHUTDOWN_PARTIAL_MS` | `1000` | 被放弃的抓取留给页面交出部分结果的时间 |
| `SHUTDOWN_SAVE_MS` | `5000` | 服务停止时，留给开着的绑定 `session_id` 的 MCP 会话写回 cookie 的时间上限（和上面的排空同时进行） |
| `SHUTDOWN_ENGINE_MS` | `1000` | 排空之后，引擎收到 SIGTERM 到被 SIGKILL 之间的等待 |
| `SHUTDOWN_HISTORY_MS` | `1000` | 最后留给历史落盘的时间 |
| `MCP_PROXY` | | MCP 浏览走的代理 URL（所有会话共用一个），格式同 `proxy` 字段 |
| `MCP_BASE_PORT` | `9300` | MCP 进程在容器内监听的第一个端口（依次加 1） |
| `LP_BIN` | `/bin/lightpanda` | MCP 进程用的引擎二进制 |

镜像额外的变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `LP_CDP_MAX_CONNECTIONS` | `2*POOL_SIZE+4` | 引擎的连接上限。要明显大于 `POOL_SIZE`：超时后服务立刻重连，而引擎可能还在拆旧连接 |
| `LP_HTTP_MAX_CONCURRENT` | `255` | 引擎所有连接共享的同时加载数上限，1–255（引擎自身默认 40，重页面会在这里排队） |
| `LP_MALLOC` | `jemalloc` | 引擎用的 malloc，`jemalloc` 或 `glibc`，见[内存](#内存) |
| `LP_LOG_LEVEL` | `info` | 引擎日志级别 |
| `LP_RESTART_DELAY` | `1` | 引擎挂掉后隔几秒重启 |
| `LIGHTPANDA_DISABLE_TELEMETRY` | `true` | 只要这个变量存在（不管值是什么）遥测就关闭 |

## 调用示例

### curl

```bash
# 最简单：默认返回 html + meta
curl -s localhost:8080/crawl -d '{"url":"https://example.com/"}'

# 要 markdown，执行一段 JS，30 秒超时
curl -s localhost:8080/crawl -H 'content-type: application/json' -d '{
  "url": "https://example.com/",
  "formats": ["markdown", "meta", "eval"],
  "js": "(async () => { window.scrollTo(0, 1e6); await new Promise(r => setTimeout(r, 500)); return document.querySelectorAll(\"a\").length })()",
  "timeout": 30000
}'

# 走代理池，带 session（cookie 会保留到下一次同 session 的请求）
curl -s localhost:8080/crawl -d '{"url":"https://shop.example/account","proxy":"pool","session_id":"shop-login-1"}'

# 查最近的失败、看状态、删 session
curl -s 'localhost:8080/history?code=timeout,navigation_failed&limit=20'
curl -s localhost:8080/health
curl -s -X DELETE localhost:8080/sessions/shop-login-1
```

### Python

只用标准库：

```python
import json
import urllib.request
import urllib.error

def crawl(url, **fields):
    body = json.dumps({"url": url, **fields}).encode()
    req = urllib.request.Request("http://crawl.internal:8080/crawl", data=body,
                                 headers={"content-type": "application/json"})
    # 客户端超时要比请求里的 timeout + PARTIAL_GRACE_MS 长
    timeout_s = fields.get("timeout", 30000) / 1000 + 10
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:   # 4xx/5xx 的响应体也是 JSON
        return e.code, json.load(e)

status, res = crawl("https://example.com/", formats=["markdown", "meta"], timeout=20000)
if status == 200:
    print(res["meta"]["status"], res["meta"]["title"])
    print(res["markdown"][:200])
elif res["error"]["code"] == "timeout" and res.get("partial"):
    # 超时但拿到了半截页面
    print("partial from", res["partial"]["source"], (res["partial"].get("markdown") or "")[:200])
else:
    print("failed:", status, res["error"]["code"], res["error"]["message"])
```

用 `requests`：

```python
import requests

r = requests.post("http://crawl.internal:8080/crawl",
                  json={"url": "https://example.com/", "formats": ["html", "meta"],
                        "proxy": "pool", "session_id": "job-42"},
                  timeout=40)
data = r.json()
if r.ok:
    html = data["html"]
    final_url = data["meta"]["url"]
else:
    code = data["error"]["code"]          # 见错误码表
    retryable = code in ("queue_full", "engine_unavailable", "engine_disconnected", "proxy_failed", "timeout", "shutting_down")
```

批量抓取时，并发数和 `POOL_SIZE` 相当即可；超过的部分只会排队，排满 `QUEUE_MAX`
后返回 503 `queue_full`。

## 请求与响应

### `POST /crawl`

```json
{
  "url": "https://example.com/",
  "formats": ["html", "markdown", "eval", "meta"],
  "js": "(async () => document.querySelectorAll('a').length)()",
  "timeout": 30000,
  "waitUntil": "load",
  "proxy": "http://user:pass@10.0.0.1:3128",
  "session_id": "shop-login-1"
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `url` | 是 | http 或 https |
| `formats` | 否 | `html`、`markdown`、`eval`、`meta` 任选。默认 `["html","meta"]`，给了 `js` 时自动加 `eval` |
| `js` | `eval` 时 | 页面加载后执行的 JS **表达式**。返回 Promise 会被等待，语句请包成 `(async () => { ... })()`；返回值必须能转成 JSON |
| `timeout` | 否 | 整个请求的毫秒数，**包括排队时间** |
| `waitUntil` | 否 | `load`（默认）、`domcontentloaded` 或 `networkidle` |
| `proxy` | 否 | 代理 URL；`"pool"` 取代理池的下一个；`"direct"` 或 `null` 不用代理。不填时直连，`PROXY_POOL_DEFAULT=true` 时走代理池 |
| `session_id` | 否 | 1–128 个 `A-Za-z0-9._-` 字符。同一个 id 的请求共享 cookie |

脚本在截取 html 和 markdown **之前**执行，所以可以先点击、展开、滚动，快照里能看到结果。

### 200 响应

只包含请求了的输出：

```json
{
  "url": "http://127.0.0.1:9790/redirect",
  "eval": { "value": 3 },
  "html": "<html><head><title>Fixture Home</title></head><body>...</body></html>",
  "markdown": "\n# Fixture Home\n\nStatic paragraph.\n...",
  "meta": {
    "url": "http://127.0.0.1:9790/index.html",
    "title": "Fixture Home",
    "status": 200,
    "statusText": "OK",
    "headers": { "content-type": "text/html; charset=utf-8" },
    "redirects": ["http://127.0.0.1:9790/redirect"],
    "cookies": [{ "name": "fixture_session", "value": "abc123", "domain": "127.0.0.1", "path": "/" }],
    "timing": { "queueMs": 0, "navigateMs": 9, "totalMs": 88 }
  }
}
```

| 字段 | 说明 |
|---|---|
| `html` | 脚本执行后的 `document.documentElement.outerHTML` |
| `markdown` | 引擎的 `LP.getMarkdown` 生成 |
| `eval` | `{ "value": ... }`；脚本抛异常时是 `{ "error": "TypeError: ..." }`，**仍然是 200** |
| `meta.url` | 页面最终的 `location.href` |
| `meta.status` / `statusText` / `headers` | 主文档最终响应（跳转之后）的状态和响应头。**目标页 404 也是一次成功抓取**：HTTP 200，`meta.status: 404` |
| `meta.redirects` | 跳转到最终页之前经过的 URL |
| `meta.cookies` | 抓取结束时浏览器上下文里的全部 cookie |
| `meta.timing` | `queueMs` 排队、`navigateMs` 加载、`totalMs` 总计（毫秒） |

## 错误码

出错时：

```json
{ "error": { "code": "timeout", "message": "request exceeded its 1500ms timeout (...)" } }
```

| HTTP | `code` | 含义 | 建议 |
|---|---|---|---|
| 400 | `bad_request` | 请求体不合法 | 改请求，别重试 |
| 404 | `not_found` | `DELETE /sessions/:id` 时没有这个 session；或路径不存在 | |
| 502 | `navigation_failed` | 主文档拿不到（DNS、拒绝连接、TLS……），也包括代理正常但到不了站点 | 站点问题，按需重试 |
| 502 | `engine_disconnected` | 抓取中引擎连接断了（引擎崩溃或重启） | 可重试 |
| 502 | `cdp_error` | 引擎拒绝了某个命令 | |
| 502 | `proxy_failed` | 代理不可用：连不上、解析不了、SOCKS 握手失败、或拒绝 CONNECT | 换代理重试 |
| 502 | `proxy_auth_failed` | 代理拒绝了账号密码（或要密码但没给） | 检查代理账号 |
| 503 | `no_proxy_available` | `proxy: "pool"`，但池里所有代理都被剔除了 | 稍后重试，看 `/health` |
| 503 | `queue_full` | 已有 `QUEUE_MAX` 个请求在排队 | 降并发或扩容后重试 |
| 503 | `shutting_down` | 服务正在停机：停机期间新发的、还在排队的、或跑过 `SHUTDOWN_DRAIN_MS` 还没完成而被放弃的（这种和超时一样可能带 `partial`），见[停机](#停机) | 换一个实例重试 |
| 503 | `engine_unavailable` | 截止前连不上引擎 | 可重试 |
| 504 | `timeout` | 超时（排队、加载或执行脚本中）；可能带 `partial` | 见下节 |
| 500 | `internal` | 服务内部错误 | 看日志 |

错误信息里出现的代理都把密码换成了 `***`。

## 超时与部分结果

`timeout` 用完就返回 504。如果请求了 `html` 或 `markdown`，服务会再花至多
`PARTIAL_GRACE_MS`（默认 2 秒）向页面要它们当前的样子，放在 `partial` 里；没来得及
回答的是 `null`。没请求 html 和 markdown 时没有 `partial`。

```json
{ "error": { "code": "timeout", "message": "..." }, "partial": { "html": "<html>...</html>", "markdown": "# ...", "source": "dom" } }
```

`partial.source`：

- `"dom"`：从页面读的，和正常完成时的 `html`/`markdown` 一样（脚本已执行）。
- `"raw-body"`：主文档的响应体没有收完，页面还没解析；`html` 是已经收到的源码
  （可能断在标签中间），`markdown` 由这段源码生成，其中的脚本不执行、引用的资源不加载。
- `null`：页面什么也没回答。

所以响应最晚在 `timeout + PARTIAL_GRACE_MS`（再加几毫秒）后返回。卡在哪里决定能拿到什么：

| 页面状态 | `partial` |
|---|---|
| 已加载但 load 事件一直不来（某个脚本或资源永远不到、`waitUntil` 达不到），或 `js` 一直不结束 | 页面当前内容，`source: "dom"` |
| 主文档还在下载 | 已到的部分，`source: "raw-body"` |
| 主文档一直没响应 | 还没有内容，`html`、`markdown` 是 `""`（之前的 about:blank） |
| 脚本死循环，或同步 `<script src>` 永远不到 | 引擎不回答任何命令，两者都是 `null`。引擎的 watchdog 在 `--watchdog-ms`（默认 30 秒）后终止脚本；在此之前该线程占满一个 CPU 核并占着一个引擎连接，`LP_CDP_MAX_CONNECTIONS` 的余量就是留给这种情况的 |

客户端自己的读超时要设得比 `timeout + PARTIAL_GRACE_MS` 长，否则会在服务返回之前断开。

## 代理与代理池

代理只作用于这一次抓取（含所有子资源请求），抓完即撤销。账号密码写在 URL 里，首个请求就带上：

| 代理 URL | 可用 | 验证方式 |
|---|---|---|
| `http://host:port`、`http://user:pass@host:port` | 是：http 页面直接转发，https 页面走 CONNECT 隧道 | 测试套件 |
| `https://host:port`（到代理走 TLS） | 自签证书需要引擎加 `--insecure-disable-tls-host-verification`（会对所有站点关闭证书校验）；CA 签发的证书应该可以但未验证 | 手工，自签 |
| `socks5://[user:pass@]host:port` | 是，引擎自己解析目标域名 | 测试套件 |
| `socks5h://[user:pass@]host:port` | 是，由代理解析域名 | 手工 |
| `socks4://`、`socks4a://` | 未验证，直接 400 | |

用户名或密码里有 URL 特殊字符（`@ : / %`）要先百分号编码。

### 区分「代理挂了」和「站点挂了」

代理连不上、密码错、站点挂了，引擎看到的往往是同一个错误（`CouldntConnect`）。所以出现这类错误后，
服务会用同样的账号密码直接问代理能不能打通到同一个站点的隧道：

| 代理的表现 | 结果 | 计入代理池失败 |
|---|---|---|
| 连不上 | `proxy_failed` | 是 |
| 拒绝账号密码或要求密码 | `proxy_auth_failed` | 是 |
| 拒绝到站点的隧道，但能连上 `PROXY_PROBE` | `navigation_failed`：站点挂了 | 否 |
| 拒绝到站点的隧道，也连不上 `PROXY_PROBE` | `proxy_failed`：代理的上游坏了 | 是 |
| 拒绝到站点的隧道，没配 `PROXY_PROBE` | `proxy_failed`，信息里说站点可能挂了 | 否 |
| 这次能打通 | `proxy_failed`，偶发 | 否 |

判断不了时不计入代理失败：因为一个站点挂了就把好代理剔除，会影响所有其他请求。配置
`PROXY_PROBE`（任何代理都能到的 host:port，比如自己的站）能消除大部分「判断不了」。
这个检查最多 2 秒，算在请求的 `timeout` 里。

### 代理池

`PROXY_POOL` 和 `PROXY_POOL_FILE` 列出代理。`"proxy": "pool"` 的请求按轮询取下一个未被剔除的代理。
不带 `proxy` 的请求默认直连（除非 `PROXY_POOL_DEFAULT=true`），这样配置了代理池也不会悄悄改变
其他调用方的网络路径。

- 代理挂了或拒绝账号密码算一次失败；页面拿到了（任何 HTTP 状态）算一次成功；超时和其他错误都不算。
- 连续失败 `PROXY_MAX_FAILS` 次被剔除 `PROXY_RETRY_AFTER_MS`；之后重新提供，再失败一次立刻再剔除，成功一次清零。
- 代理失败的 `"pool"` 请求会换一个没试过的代理重跑，最多 `PROXY_POOL_RETRIES` 次，用同一个浏览器槽位、
  **共用同一个 `timeout`**。站点挂了（`navigation_failed`）不重试。用完重试仍失败时返回最后一个错误，
  信息里写明试了几个代理。指定了具体代理 URL 的请求永远不换代理。
- 各代理当前状态见 `/health` 的 `proxies` 或管理页。

## Session

同一个 `session_id` 的抓取共享 cookie：抓取开始前把 cookie 放进新的浏览器上下文，结束前再读回来合并
（超时后页面还能回答的话也会读回）。只保存 cookie，不保存 localStorage 和缓存。

- 镜像里 `SESSION_DIR=/data/sessions`，每个 session 写成 `<session_id>.json`，在响应发出前落盘，重启后还在。
- 闲置 `SESSION_TTL_MS`（默认 7 天）的 session 整个删除（启动时和每 `SESSION_SWEEP_MS` 清理一次；
  过了 TTL 再用会从空 cookie 开始，不必等清理）。单个 cookie 也按自己的 Expires/Max-Age 过期。
- 同一 session 的两个请求并发时，各自从开始时的 cookie 出发，结束时按 cookie（name、domain、path）合并：
  自己设置或修改的写入，自己开始时有、结束时没了的删除，没动过的不碰；两边改了同一个 cookie，后结束的赢。
- `DELETE /sessions/<session_id>` 立即删除：`200 {"deleted": "<id>"}`，没有则 404。删除时正在跑的同 session
  抓取不会把它写回来。
- `GET /sessions?limit=200` 按最近使用倒序列出 session：

  ```json
  { "total": 2, "sessions": [
    { "id": "shop-login-1", "lastUsed": "2026-10-22T00:19:17.618Z", "expiresAt": "2026-10-29T00:19:17.618Z", "cookies": 4, "domains": ["shop.example"], "loaded": true }
  ] }
  ```

  只给 cookie 数和域名，**不给 cookie 的值**。`loaded` 表示是否在内存里（否则只在磁盘上）。
- **多副本时 session 是各副本自己的**：副本会把用过的 session 留在内存里，所以负载均衡要按 `session_id`
  做哈希，让同一个 session 总是落到同一个副本。
- **MCP 会话也能用同一个 session**：连 `/mcp?session_id=<id>`，agent 的浏览器从这个 session 的 cookie 出发，
  它登录拿到的 cookie 也写回这里，规则同上；会话开着时别人写进 session 的 cookie，下一次调用前也会同步进它的浏览器。见 [与 /crawl 的 session 互通](#与-crawl-的-session-互通session_id)。

## Agent 接入（MCP）

`/mcp` 是 [MCP](https://modelcontextprotocol.io/)（Model Context Protocol）的 Streamable HTTP 接口。
agent 连上后得到一个**属于它自己的浏览器**，用 `goto`、`click`、`fill`、`press`、`scroll`、
`waitForSelector`、`markdown`、`extract`、`evaluate` 等工具一步步操作页面，页面状态在调用之间保留——
和 Playwright 驱动一个浏览器是一样的用法。`/crawl` 适合「一个 URL 进、一份结果出」；要看了页面
再决定下一步（找按钮、翻页、填表、登录）就用 MCP。

### Claude Code

```bash
claude mcp add --transport http crawl http://crawl.internal:8080/mcp
```

或者写进项目的 `.mcp.json` / 用 `--mcp-config` 传入：

```json
{ "mcpServers": { "crawl": { "type": "http", "url": "http://crawl.internal:8080/mcp" } } }
```

非交互地跑一个任务（工具名是 `mcp__crawl__<工具>`；`--tools ""` 关掉内置工具，只用浏览器）：

```bash
claude -p "打开 http://shop.example/list ，点下一页直到最后一页，汇总每页商品的编号、标题、价格，输出 JSON" \
  --mcp-config crawl-mcp.json --strict-mcp-config --tools "" --allowedTools "mcp__crawl"
```

### 其他 MCP 客户端

任何支持 Streamable HTTP 的 MCP 客户端（Claude Desktop、Cursor、OpenAI Agents SDK、LangChain 的
MCP 适配器、官方 Python / TypeScript SDK……）填同一个 URL 即可。服务只回 JSON（不发 SSE 事件流，
`GET /mcp` 返回 405，这是协议允许的）。

不用 SDK 时，协议就是几个 POST：

```bash
# 1. initialize：响应头 mcp-session-id 就是你的浏览器
curl -si localhost:8080/mcp -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"me","version":"1"}}}' | grep -i mcp-session-id
# mcp-session-id: mcp-9b82a0a916bd8109c7d10eb7

# 2. 之后每个请求都带上它
S=mcp-9b82a0a916bd8109c7d10eb7
curl -s localhost:8080/mcp -H 'content-type: application/json' -H "mcp-session-id: $S" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"goto","arguments":{"url":"https://example.com/"}}}'
curl -s localhost:8080/mcp -H 'content-type: application/json' -H "mcp-session-id: $S" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click","arguments":{"selector":"a.next"}}}'

# 3. 用完关掉（不关也会在 MCP_SESSION_IDLE_MS 后被回收）
curl -s -X DELETE localhost:8080/mcp -H "mcp-session-id: $S"
```

`tools/call` 的结果是 `{"content":[{"type":"text","text":"..."}],"isError":false}`；工具失败（比如选择器
找不到元素）是 `isError: true`，HTTP 仍是 200。`tools/list` 列出全部工具和参数说明。
仓库里的 [`service/test/mcp-client.mjs`](test/mcp-client.mjs) 是一个 60 行、零依赖的 Node 客户端，可以直接拿去用。

### 多会话与并发

- **一次 `initialize` 就是一个独立的浏览器**（引擎里一个单独的浏览器实例）：自己的页面和 cookie。多个 agent
  各自 `initialize` 就互不干扰（实测两个会话同时打开不同页面、cookie 互不可见）。会话 id 是服务端生成的
  随机串，没有 `mcp-session-id` 头的请求（`initialize` 除外）返回 400，不认识的 id 返回 404——
  按 MCP 协议，客户端收到 404 应该重新 `initialize`。
- 想让两个 agent **故意共用**一个浏览器，就让它们带同一个 `mcp-session-id`。
- **并发**：每个 `lightpanda mcp` 进程同一时间只执行一个工具调用（引擎里所有会话共用一个线程），
  实测同一进程里一个会话打开 4 秒的慢页面时，另一个会话打开快页面也要等 3.8 秒。所以服务开
  `MCP_PROCS` 个进程，新会话分到会话最少的进程上，之后一直留在那个进程。同时在跑工具调用的 agent
  多于进程数时，同一进程上的调用排队。实测 `MCP_PROCS=2`：一个会话打开 3 秒的慢页面时，另一个会话
  打开页面只用了 21 毫秒。
- 资源：空闲的 MCP 进程每个约 8–9 MB（同一镜像 `MCP_PROCS=2` 比 `0` 多 17 MB）；每个会话是一个浏览器，
  内存和打开的页面有关（4 个会话、其中 3 个跑完翻页后，整个容器 70 MB）。要更多并发就加 `MCP_PROCS`，会话上限是 `MCP_MAX_SESSIONS`。
- 会话 `MCP_SESSION_IDLE_MS`（默认 30 分钟）没有调用就关闭。**Claude Code 跑完 `claude -p` 不会发
  DELETE**，会话就是靠这个回收的；自己写的客户端用完请 `DELETE`。
- 某个 MCP 进程挂了会自动重启，它上面的会话丢失（之后返回 404，历史里记一行 `session_lost`），
  其他进程上的会话不受影响。
- 当前会话列表：`GET /mcp/sessions`（id、绑定的 `session_id`、所在进程、开始时间、最后调用、调用次数、
  当前页面），管理页的状态标签里也有。
- 多副本部署时，同一个会话的请求必须落到同一个副本（负载均衡按 `mcp-session-id` 头做粘性）。

### 与 /crawl 的 session 互通（`session_id`）

MCP 会话默认从空 cookie 开始，和 `/crawl` 的 [session](#session) 不相干。在 URL 上带 `session_id`，这个 MCP 会话
就和同名的 `/crawl` session 共用 cookie：用 `/crawl` 登录过的，agent 一打开页面就是已登录；agent 在浏览器里
登录的，`/crawl` 带同一个 `session_id` 也是已登录。

```json
{ "mcpServers": { "crawl": { "type": "http", "url": "http://crawl.internal:8080/mcp?session_id=shop-login-1" } } }
```

```bash
claude mcp add --transport http crawl 'http://crawl.internal:8080/mcp?session_id=shop-login-1'
```

- **在 `initialize` 时生效**：服务把这个 session 的全部 cookie（含 HttpOnly 的）放进新浏览器。之后请求上的
  `session_id` 不再看，一个 MCP 会话从头到尾只绑一个 session。`session_id` 的格式同 `/crawl`（1–128 个
  `A-Z a-z 0-9 . _ -`），不合法返回 400。
- **双向同步**，以 session 为准，浏览器是它的一份副本：
  - **写出：每个工具调用之后、把结果交给 agent 之前**，再加上会话结束时（`DELETE`、闲置回收或服务停止）
    各一次。所以 agent 看到「点了登录」的结果时，cookie 已经在 session 里了，紧接着发的 `/crawl` 就能用上；
    会话结束那一次补上最后一次调用之后页面脚本才设的 cookie。写出按 [Session](#session) 的合并规则：只写
    这个会话自己改过的 cookie（和它上一次同步时比），别人这期间改的不会被它盖掉。没有变化时不写盘。
  - **拉入：每个工具调用之前**，如果自这个会话上一次同步以来别人（`/crawl`，或绑同一个 `session_id` 的另一个
    MCP 会话）改过 session，就把浏览器改成和 session 一致：新增和改过的 cookie（含 HttpOnly）放进去，session
    里已经没有的从浏览器删掉。所以 MCP 开着时用 `/crawl` 登录，agent 下一步打开的页面就是已登录；`/crawl`
    访问登出页让站点删掉 cookie，MCP 里下一步也没了。
  - **冲突规则：同一个 cookie（name、domain、path）两边都改了，后到 session 的赢**，和两个并发 `/crawl` 一样。
    浏览器里的改动在每次调用结束时到达 session；两次调用之间页面脚本自己改的，在下一次调用开始时（拉入之前
    先写出一次）才到达。所以「上一次调用结束后，页面脚本和 `/crawl` 改了同一个 cookie」时，页面脚本的改动
    后到、它赢；其余情况都是谁先写进 session 谁先、后写的盖掉前面的。不同的 cookie 互不影响。
- **代价**：写出是每次调用多一次引擎往返（导出 cookie）。拉入只在 session 被别人改过时才有：判断「有没有被改过」
  是内存里比一个版本号，不调用引擎；被改过的那一次多一次导出和一次导入。2026-10-22 在 bt 上，session 里 21 个 cookie、各 200 次调用的中位数（两轮）：没被改过时与只写出的上一版
  持平（`getUrl` 1.62/2.55→1.67/2.24 毫秒，`goto` 小页面 9.05/12.30→10.17/9.26 毫秒，差异在机器噪声内）；每次调用前都有
  `/crawl` 改一个 cookie 的极端情况，`getUrl` 多 1.1–1.9 毫秒、`goto` 多 2.1–2.2 毫秒。cookie 没变的调用不写盘。
- **进程挂了**：引擎进程挂掉时会话丢失，session 里留下的是最后一次调用之后的 cookie（只丢最后一次调用之后、
  页面脚本自己设的那部分），历史里的 `session_lost` 行会写明。
- **服务停止**：收到 SIGTERM/SIGINT（`docker stop`、`docker compose down`）时，服务先拒绝新的 `/mcp` 请求
  （503），等每个绑定会话手上的调用结束，再给它们写出最后一次、落盘，然后才退出；整个写出最多等
  `SHUTDOWN_SAVE_MS`（默认 5 秒），和 `/crawl` 的排空同时进行，整个停机在 `docker stop` 默认的 10 秒宽限之内（见[停机](#停机)）。日志里有一行
  `mcp cookies saved on shutdown`（会话数、写出数、是否超时、耗时）。实测（bt，`docker stop`）：最后一次调用后页面脚本设的 cookie，停容器再起新容器后 `/crawl` 能看到，
  `docker stop` 用时约 0.6 秒、写出 5–6 毫秒、退出码 0；上一版镜像同样操作后这个 cookie 丢失。镜像里 PID 1 是 tini，
  Node 是它的子进程、收得到转发的 SIGTERM；MCP 引擎进程放在自己的进程组里，不会和 Node 同时被这个信号结束。被 `kill -9` 或宽限超时被强杀时
  没有这一次，丢的是最后一次调用之后页面脚本设的 cookie。
- 两个 MCP 会话可以绑同一个 `session_id`（各自一个浏览器，按上面的规则双向同步，一边登录、另一边下一步就是
  已登录），绑不同 `session_id` 的互不相干。
- 看绑定：`GET /mcp/sessions` 和管理页的「MCP 会话」表有 `session_id` 一列；绑定会话的每一行历史都带
  `session_id`，所以 `GET /history?session_id=shop-login-1` 会同时列出这个 session 的 `/crawl` 请求和
  MCP 调用。`session_start` 那一行写着带入了几个 cookie。

### 代理

MCP 浏览走 `MCP_PROXY`（一个代理 URL，所有会话共用，支持的格式同 `/crawl` 的 `proxy` 字段，账号密码写在
URL 里）。没有按会话或按调用选代理，也**不走代理池**：引擎的 MCP 工具没有代理参数，代理是 MCP 进程
启动时定的。需要不同出口时，起多个容器各配一个 `MCP_PROXY`。

### 工具说明

可用工具：`goto`、`markdown`、`html`、`tree`、`links`、`interactiveElements`、`findElement`、`nodeDetails`、
`extract`、`structuredData`、`detectForms`、`evaluate`、`click`、`fill`、`press`、`hover`、`scroll`、
`selectOption`、`setChecked`、`waitForSelector`、`waitForScript`、`waitForState`、`screenshot`、
`consoleLogs`、`getUrl`、`getCookies`、`getEnv`、`search`。initialize 的响应里有一大段 `instructions`
（工具的用法建议），MCP 客户端会交给模型。

- 引擎原有的 `session_new`、`session_list`、`session_close` 和 `save` 不提供：前三个能列出、加入、关闭
  别人的会话，`save` 会往容器里写文件。调用它们会得到 `isError` 的结果。新会话请用 `initialize`。
  引擎的 `cookies_import` / `cookies_export` 是服务实现 `session_id` 用的，也不给 agent。
- `getEnv` 和 `$LP_*` 占位符：MCP 进程不带任何 `LP_*` 环境变量启动，所以没有可用的凭据占位符。
- `screenshot` 渲染的是引擎的文字布局，不是真实像素截图。
- `search` 会去访问搜索引擎。

### 伪装

MCP 进程带 `--no-webmcp` 启动，页面里 `typeof navigator.modelContext`、`typeof ModelContext`、
`typeof ModelContextClient` 都是 `"undefined"`，`Navigator.prototype` 上也没有这个名字（引擎的 `mcp`
命令原本会挂上这三个 Chrome 没有的名字，Kasada 实测会读）。同一个页面分别经 `/crawl` 和 MCP 打开，
主文档的 14 个请求头和 `navigator.userAgent` / `webdriver` / `plugins` / `languages` 完全相同。
测试套件每次都检查这几项。

### 实测：agent 找翻页按钮点到底

2026-10-22 在 bt 上，`claude -p`（Sonnet 5.5）经 SSH 隧道连容器的 `/mcp`，浏览器在 bt 的容器里跑。页面是
测试用的商品列表（[`service/test/paging-server.mjs`](test/paging-server.mjs)），提示词只说「找到翻页按钮
一页页点到最后一页，汇总每页商品」，没给选择器：

| 页面 | agent 的工具调用 | 结果 |
|---|---|---|
| 链接翻页（5 页，每页一个 URL），要求点击「下一页」 | `markdown{url}` → `interactiveElements` → 4 ×（`click a.next` → `markdown`） | 25 条全对，17.5 秒 |
| 链接翻页，没要求必须点击 | `markdown{url}` → `links` → 直接 `markdown{url}` 打开第 2–5 页 | 25 条全对，13 秒 |
| ajax 翻页（4 页，URL 不变） | `goto` → `interactiveElements` → `html` → 3 ×（`click #next` → `extract`） | 20 条全对，14 秒 |

ajax 型里 agent 点击后直接 `extract`，读到的就是新一页（测试页的接口延迟 150 毫秒；更慢的站点让
agent 用 `waitForSelector` / `waitForScript` 等内容变化）。每一步调用都在
[请求历史](#请求历史)里（`kind: "mcp"`），点击那一行的 `url` → `finalUrl` 就是从第几页翻到了第几页。

## 翻页

三种做法，从简单到灵活：

1. **交给 agent**：用 [MCP](#agent-接入mcp)，告诉它「点下一页直到最后一页」。页面结构未知、每个站
   不一样时最省事。
2. **ajax 翻页**（点「下一页」只换列表、URL 不变）：一次 `/crawl`，在 `js` 里循环点击。
3. **链接翻页**（每页一个 URL）：调用方循环，每次 `/crawl` 的 `js` 返回本页数据和下一页链接，
   带同一个 `session_id`。

下面两段代码在 bt 上对测试页面实跑通过（测试套件第 19 节，每次都跑）。

### ajax 翻页：一次请求里循环点击

```json
{
  "url": "https://shop.example/list",
  "formats": ["eval"],
  "timeout": 60000,
  "js": "(async () => { const sleep = (ms) => new Promise((r) => setTimeout(r, ms)); const pages = []; for (let n = 1; n <= 50; n++) { pages.push([...document.querySelectorAll('li.item')].map((li) => ({ id: li.dataset.id, title: li.querySelector('.title').textContent }))); const next = document.querySelector('#next'); if (!next) break; const before = document.querySelector('#list').innerHTML; next.click(); for (let i = 0; i < 100 && document.querySelector('#list').innerHTML === before; i++) await sleep(100); } return pages; })()"
}
```

`js` 展开后：

```js
(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const pages = [];
  for (let n = 1; n <= 50; n++) {                      // 最多 50 页，防止死循环
    pages.push([...document.querySelectorAll('li.item')].map((li) => ({
      id: li.dataset.id, title: li.querySelector('.title').textContent })));
    const next = document.querySelector('#next');      // 末页没有下一页按钮就结束
    if (!next) break;
    const before = document.querySelector('#list').innerHTML;
    next.click();
    // 等列表内容变化（最多 10 秒），而不是固定睡一段时间
    for (let i = 0; i < 100 && document.querySelector('#list').innerHTML === before; i++) await sleep(100);
  }
  return pages;
})()
```

`eval.value` 是每页一个数组。上面的 JSON 请求体原样在 bt 上跑过；4 页、每页一次 150 毫秒的接口请求，
整个请求 0.64 秒。

- 选择器（`li.item`、`#next`、`#list`）换成目标站的；末页的判断按站点改：按钮消失、`disabled`、
  或者带某个 class。
- **整个循环共用一个 `timeout`**（包括页面加载），页数多就把 `timeout` 调大（最大 `MAX_TIMEOUT_MS`，
  默认 120 秒）。超时了拿不到 `eval`，只有 `partial` 里的页面快照，所以宁可分几次。
- 「加载更多」/ 无限滚动是同一个写法：点按钮或 `window.scrollTo(0, document.body.scrollHeight)`，
  等条目数变多，最后一次性收集。

### 链接翻页：调用方循环

`js` 返回本页数据和下一页的绝对链接（`a.href` 已经是绝对地址），没有下一页时是 `null`：

```js
(() => ({
  items: [...document.querySelectorAll('li.item')].map((li) => ({
    id: li.dataset.id, title: li.querySelector('.title').textContent })),
  next: document.querySelector('a.next')?.href ?? null,
}))()
```

Python：

```python
import requests

JS = """(() => ({
  items: [...document.querySelectorAll('li.item')].map((li) => ({ id: li.dataset.id, title: li.querySelector('.title').textContent })),
  next: document.querySelector('a.next')?.href ?? null,
}))()"""

def crawl_all(start_url, session_id, max_pages=50):
    items, url = [], start_url
    for _ in range(max_pages):
        r = requests.post("http://crawl.internal:8080/crawl",
                          json={"url": url, "js": JS, "formats": ["eval"], "session_id": session_id},
                          timeout=40)
        r.raise_for_status()
        value = r.json()["eval"]["value"]
        items += value["items"]
        url = value["next"]
        if not url:
            break
    return items

items = crawl_all("https://shop.example/list?page=1", session_id="shop-list-1")
```

这段 Python 原样在 bt 上跑过（25 条全对）；测试套件里同样逻辑的 Node 循环 5 页 5 个请求共 0.12 秒。

- 每次 `/crawl` 是一个新的浏览器上下文：**只有 cookie** 靠 `session_id` 带到下一页（登录态、站点
  的分页 cookie），localStorage、内存里的 JS 状态都不保留。翻页依赖这些的站点用 MCP。
- 下一页是「表单提交」或者 JS 跳转、拿不到链接的，也用 MCP（或者在 `js` 里点了之后读 `location.href`，
  但那一次的结果还是旧页面的）。
- 每页一个请求，可以并发抓不同的列表；同一个列表的页是串行的。

## 请求历史

设置了 `HISTORY_DIR`（镜像默认 `/data/history`）时，每个 `POST /crawl`——成功、失败、超时、参数错误
（400）——以及每个 MCP 工具调用都会写一行 JSON 到 `HISTORY_DIR/crawl-YYYY-MM-DD.<副本>.jsonl`（日期按 **UTC**）。
同一行也打到 stdout（`docker logs` 里能看到）。**只记录发生了什么，不保存页面内容。**

样例（一次超时，带回了部分结果）：

```json
{"time":"2026-10-22T00:18:56.217Z","kind":"crawl","url":"http://172.17.0.1:41879/slow-load","finalUrl":"http://172.17.0.1:41879/slow-load","status":504,"code":"timeout","message":"request exceeded its 1500ms timeout (...)","pageStatus":200,"ms":1504,"queueMs":0,"proxyMode":"direct","proxy":null,"proxiesTried":0,"session_id":null,"formats":["html","markdown","meta"],"htmlBytes":null,"markdownBytes":null,"partial":{"source":"dom","htmlBytes":147,"markdownBytes":36},"replica":"6f0888d64ad7"}
```

| 字段 | 说明 |
|---|---|
| `time` | 响应发出的时间（UTC） |
| `url` / `finalUrl` | 请求的 URL；主文档跳转后的最终 URL（请求了 `meta` 时是 `location.href`）。URL 里的密码换成 `***` |
| `status` / `code` / `message` | 本服务返回的 HTTP 状态、错误码（成功为 `null`）和错误信息 |
| `pageStatus` | 目标页主文档的 HTTP 状态（收到了才有，超时后也会记） |
| `ms` / `queueMs` | 总耗时、排队耗时（毫秒） |
| `proxyMode` / `proxy` / `proxiesTried` | `direct` / `pool` / `url`；最后用的代理（密码打码）；试过几个池代理 |
| `session_id` / `formats` | 请求里的 session 和输出格式 |
| `htmlBytes` / `markdownBytes` | 返回的 html / markdown 的 UTF-8 字节数，没返回为 `null` |
| `partial` | 超时带回部分结果时：`source` 及其中 html / markdown 的字节数 |
| `replica` | 写这行的副本 |
| `kind` | `crawl`（`POST /crawl`）或 `mcp`（MCP 工具调用）。没有这个字段的旧行算 `crawl` |

MCP 的行和 `/crawl` 的行字段相同（不适用的为 `null`），另有 `tool`、`mcp_session`、`mcp_process`、
`args`、`resultBytes`。一次 agent 点击翻页：

```json
{"time":"2026-10-22T01:49:06.503Z","kind":"mcp","tool":"click","url":"http://172.17.0.1:32871/links/1","finalUrl":"http://172.17.0.1:32871/links/2","status":200,"code":null,"message":null,"pageStatus":null,"ms":11,"queueMs":null,"proxyMode":"url","proxy":"http://user:***@172.17.0.1:18575","proxiesTried":0,"session_id":null,"mcp_session":"mcp-707c836f23ba051c64f225a8","mcp_process":"mcp0","args":{"selector":"a.next"},"resultBytes":108,"replica":"9a206d73dcd8"}
```

| 字段（MCP） | 说明 |
|---|---|
| `tool` | 工具名；另有 `session_start`、`session_end`（客户端 DELETE 或闲置过期，`message` 写原因）、`session_lost`（进程挂了） |
| `url` / `finalUrl` | 调用参数里的 `url`（没有时是调用前所在的页面）；调用后所在的页面。`goto`、`click`、`press` 之后服务会问一次引擎当前 URL，所以点链接翻页能看到去了哪 |
| `code` / `message` | 成功为 `null`；`tool_error`（工具报错，`message` 是错误文字）、`timeout`（`goto` 没等到加载完）、`rpc_error`、`engine_error`（连不上 MCP 进程） |
| `ms` | 这次调用的耗时；会话事件是会话已存在的时长 |
| `mcp_session` / `mcp_process` | 会话 id；所在的 MCP 进程 |
| `session_id` | 会话用 `/mcp?session_id=` 绑定的 `/crawl` session（每一行都带），没绑定为 `null` |
| `args` | 调用参数的摘要：选择器、按键之类的短参数，长字符串截到 200 字符，`fill` 的值只记长度，不含 `url` |
| `resultBytes` | 工具返回文字的字节数（不保存内容） |

- **代价**：小页面压测（`bench/profile/ab.sh`，与不带历史的镜像对比，同一个引擎二进制，各 3 轮）：写文件本身
  测不出影响（16 槽位：有历史 723 / 716 / 750 页每秒，`HISTORY_DIR` 置空 718 / 726 / 731）；更完整的那一行
  （大小、最终 URL、代理等）在 16 槽位、Node 单核是瓶颈时少 3–4%（726 对 760），64 槽位少不到 2%（1,078 对 1,103）。
- **不拖慢请求**：记录先进内存队列，每秒批量追加一次。写盘失败只打到 stderr 并计入 `/health` 的
  `history.writeErrors`，不影响响应。磁盘一直写不进去时队列最多留 10 万行，再多就丢最旧的（计入 `dropped`）。
- **多副本**：共用一个卷的副本（`crawl-multi`）各写各的文件（文件名带容器 id），任何一个副本的
  `GET /history` 都会读所有副本的文件。
- **保留**：比 `HISTORY_RETENTION_DAYS`（默认 7 天，含今天）更早的文件在启动时和每小时删除。默认 7 天的理由：
  够查「昨天、上周发生了什么」，又不至于把盘写满——每行约 0.4 KB（小页面压测 11.6 万行平均 376 字节，
  URL 和错误信息长时更大），磁盘占用跟着请求量走：每秒 10 个请求一天约 0.3 GB；一个 16 槽位的容器跑满小页面
  （每秒约 700 个）一天约 23 GB。
  量大时调小保留天数，或者把 `/data` 放到足够大的盘上。

### `GET /history`

```
GET /history?url=shop.example&code=timeout,navigation_failed&since=2026-10-21T00:00:00Z&limit=50
```

| 参数 | 说明 |
|---|---|
| `url` | `url` 或 `finalUrl` 包含的子串，不分大小写 |
| `status` | 本服务的 HTTP 状态，逗号分隔（`200,504`） |
| `code` | 错误码，逗号分隔；`ok` 表示成功 |
| `session_id` | 精确匹配；也匹配 MCP 行的 `mcp_session`。绑定了这个 session 的 MCP 会话的行也会列出 |
| `kind` | `crawl` 或 `mcp` |
| `since` / `until` | ISO 时间或毫秒时间戳 |
| `days` | 不给 `since` 时往前查几天（含今天），默认 3 |
| `limit` | 1–1000，默认 100 |

返回按时间倒序：

```json
{ "enabled": true, "entries": [ ... ], "scanned": { "files": 2, "lines": 80, "unreadable": 0 }, "from": "2026-10-20T00:00:00.000Z" }
```

查询从最新的一天往前逐行读文件，凑够 `limit` 条就停。繁忙容器一天的文件可能很大，查长时间范围会慢，
尽量用 `since` / `days` 缩小范围。没设 `HISTORY_DIR` 时返回 `{"enabled": false, "entries": []}`。

## 管理页

浏览器打开 `http://<服务地址>:8080/`。一个静态页面（内联样式和脚本，不加载任何外部资源），四个标签：

- **状态**：每 3 秒读一次 `/health`——连接池的槽位、忙、闲、已连接、排队、重连次数；代理池每个代理
  可用还是被剔除、使用/成功/失败次数和最近错误；session 和请求历史的统计；MCP 进程、会话数和调用
  统计，以及当前 MCP 会话列表（含绑定的 session_id；点一行看这个会话的全部调用）。
- **请求历史**：按 URL、HTTP 状态、错误码、类型（crawl / mcp）、session_id（也匹配 MCP 会话）、时间范围、
  天数、条数筛选；MCP 的行在「输出 / 工具」列显示工具名和选择器；点一行看完整记录；可选每 10 秒自动刷新。
- **试抓**：填一个 URL，选输出（html / markdown / meta / eval 加 JS）、代理（直连 / 代理池 / 指定 URL）、
  session_id、timeout、waitUntil，直接调 `/crawl` 并显示结果、meta 和耗时；长文本先显示前 2 万字符。
- **Session**：列出 session（最后使用、过期时间、cookie 数、域名），可以跳到该 session 的历史，或删除。

管理页和接口一样不鉴权，只放内网。

## 健康检查 `GET /health`

```json
{
  "ok": true,
  "stopping": false,
  "pool": { "size": 4, "busy": 1, "connected": 3, "queued": 0, "reconnects": 0 },
  "proxies": { "size": 2, "active": 1, "maxFails": 3, "retryAfterMs": 60000, "proxies": [
    { "proxy": "http://user:***@10.0.0.1:3128", "state": "active", "uses": 41, "ok": 40, "failed": 1, "consecutiveFails": 0, "lastError": "..." }
  ] },
  "sessions": { "persisted": true, "dir": "/data/sessions", "ttlMs": 604800000, "stored": 30, "loaded": 12, "saves": 340, "writeErrors": 0, "expired": 4, "deleted": 1, "lastSweep": "..." },
  "history": { "enabled": true, "dir": "/data/history", "replica": "6f0888d64ad7", "retentionDays": 7, "written": 38, "queued": 0, "writeErrors": 0, "dropped": 0, "lastError": null, "removedFiles": 0, "lastSweep": "..." },
  "mcp": { "enabled": true, "processes": [
    { "name": "mcp0", "pid": 47, "up": true, "sessions": 2, "inFlight": 0, "calls": 18, "restarts": 0 }
  ], "sessions": 4, "maxSessions": 32, "idleMs": 1800000, "proxy": null, "started": 4, "closed": 0, "expired": 0, "lost": 0, "calls": 25, "toolErrors": 0, "refused": 0, "cookieSaves": 9, "cookieSaveErrors": 0, "cookiePulls": 2, "cookiePullErrors": 0 }
}
```

- **停机中**返回 **503**，`"ok": false`，`stopping` 是
  `{ "signal": "SIGTERM", "since": "…", "phase": "draining", "inFlight": 2 }`（`phase` 依次是 `draining` →
  `stopping engines` → `writing history`）。负载均衡按状态码做健康检查即可立刻摘掉这个实例。
- `pool.busy` 长期等于 `size` 且 `queued` 在涨：并发不够，扩容。
- `pool.reconnects` 在涨：超时或引擎重启后的重连，偶尔有正常。
- `proxies` 没配代理池时是 `null`；`state: "ejected"` 的代理带 `retryInMs`。
- `sessions.stored` 是现有 session 数，`loaded` 是在内存里的；`expired`/`deleted` 是启动以来的计数。
- `history.written` 是启动以来写入的行数，`queued` 是还没落盘的，`writeErrors`/`dropped` 不为 0 要查磁盘。
- `mcp.processes[].up` 为 false 是进程正在重启；`lost` 是因进程挂掉丢失的会话数；`refused` 是被拒绝的
  `session_*` / `save` 调用数；`cookieSaves` / `cookieSaveErrors` 是绑定 `session_id` 的会话写回 cookie 的
  次数和失败数，`cookiePulls` / `cookiePullErrors` 是把别人写进 session 的 cookie 拉进浏览器的次数和失败数
  （失败只记数和打日志，不影响调用）。`MCP_PROCS=0` 时是 `{"enabled": false}`。

## 停机

收到 SIGTERM 或 SIGINT（`docker stop`、`docker compose down`、Ctrl-C）后：

1. **立刻**：`/health` 返回 503（带 `stopping`）；新的 `/crawl` 返回 503 `shutting_down`，新的 `/mcp` 请求返回
   503；之后的每个响应都带 `Connection: close`。**还在排队等槽位的请求也立刻返回 503 `shutting_down`**：
   它们还没开始，调用方现在就能转到别的实例，不必陪着等完排空再被拒。
2. **排空，最多 `SHUTDOWN_DRAIN_MS`（5 秒）**：在飞的 `/crawl` 继续跑。到时还没跑完的**被放弃**：页面再有
   `SHUTDOWN_PARTIAL_MS`（1 秒）交出已有内容，响应是 503 `shutting_down`，带 `partial`，格式和超时时一样
   （见[超时与部分结果](#超时与部分结果)），session 的 cookie 照常保存。与此同时，绑定 `session_id` 的
   MCP 会话写回 cookie（最多 `SHUTDOWN_SAVE_MS`，5 秒）。
3. **关引擎，最多 `SHUTDOWN_ENGINE_MS`（1 秒）**：给 `serve` 引擎的进程组和 MCP 引擎发 SIGTERM，到时还在的发 SIGKILL。
4. **历史落盘，最多 `SHUTDOWN_HISTORY_MS`（1 秒）**，然后以退出码 0 退出。

每个被拒绝或被放弃的请求在历史里都有一行：`code` 为 `shutting_down`，`message` 写明原因（停机期间新发的 /
还在排队 / 跑过 `SHUTDOWN_DRAIN_MS` 被放弃），被放弃的还记了部分结果的大小。日志在收到信号时有一行 `stopping`，
退出前有一行 `stopped`（从队列拒掉几个、在飞几个、放弃几个、引擎是否被强杀、各段耗时）。

默认值下最坏情况是 5 + 1（+0.5 余量）+ 1 + 1 = 8.5 秒，在 `docker stop` 默认的 10 秒宽限之内；没有在飞请求时
停机不到 1 秒。**要让更长的抓取跑完**，把 `SHUTDOWN_DRAIN_MS` 和宽限期一起调大，宽限期要大于
`max(SHUTDOWN_DRAIN_MS + SHUTDOWN_PARTIAL_MS + 500, SHUTDOWN_SAVE_MS) + SHUTDOWN_ENGINE_MS + SHUTDOWN_HISTORY_MS`
再留一两秒。例如要等 30 秒的抓取：

```yaml
services:
  crawl:
    stop_grace_period: 35s
    environment:
      SHUTDOWN_DRAIN_MS: 30000
```

不用 compose 时是 `docker stop -t 35` 或 `docker run --stop-timeout 35`。各段之和超过 9.5 秒时服务启动时会打一行
warning。超过宽限期 Docker 会 SIGKILL，那时还在飞的请求既拿不到响应、也不会有历史记录。

实测（bt，`lp-crawl:drain`）：DRAIN_RESULTS_ZH

为什么要把引擎放进自己的进程组：镜像里 PID 1 是 `tini -g`，它把 `docker stop` 的 SIGTERM 发给子进程所在的整个进程组。
以前 `serve` 引擎也在这个组里，和服务同时被结束，在飞的抓取全部失败（上一版镜像约 0.6 秒内服务就退出了，
客户端连响应都拿不到）。

## 扩容建议

以下数字来自 `service/bench/`，在 512 核（2 × 128 核 EPYC）的机器上测得，详见英文 README 的 Scaling 一节。

### 加容器，而不是加槽位

一个容器是一个引擎进程加一个 Node 进程，两者各有单进程上限：

- 服务（一个 Node 核）对小页面约每秒 1,000–1,100 个封顶：`POOL_SIZE=16` 时 700–760，32 时 930–1,050，64 时 1,000–1,100。
- 引擎单独跑远高于此：16 / 32 / 64 连接每秒 1,250 / 2,100 / 3,300 个小页面。
- 四个 16 槽位的容器每秒 2,500–2,600 个小页面，一个 64 槽位的容器只有 800。

所以：**每个容器 `POOL_SIZE=16`，内存允许可以到 32**（小页面多四分之一到一半的吞吐，内存翻倍），**不要超过 32**——
超过以后瓶颈在 Node 进程，加槽位只加内存不加吞吐。要更多并发就加容器（`crawl-multi` 的 `CRAWL_REPLICAS`）。

### CPU

每个忙碌的槽位约占 1 个核（页面线程加 V8 后台线程）。给每个容器的 `--cpus` 至少 **1.3 × `POOL_SIZE`**
（compose 的 `crawl-multi` 给 16 槽位配 21 个 CPU）；少于这个数，CFS 限流的损失比省下的核还多
（16 槽位只给 16 核时小页面少了 27%；8 核跑重页面每秒 6 个而不是约 9 个）。

### NUMA：用 `CRAWL_CPUSET` 钉在一个节点上

多 NUMA 节点的机器上，把每个容器钉在一个节点的核上。同一时间窗口内，钉住后的吞吐变化：

| | 16 | 32 | 64 |
|---|---|---|---|
| 引擎单独（`--mode cdp`） | +23% | +36% | +47% |
| 经过服务 | −8% | +12% | +10% |

16 槽位时瓶颈在 Node 进程，钉不钉差别不大；槽位越多收益越大。用 `lscpu | grep NUMA` 或
`/sys/devices/system/node/node*/cpulist` 找各节点的核，然后 `docker run --cpuset-cpus`，或 compose 里的
`CRAWL_CPUSET`。多副本时每个节点一个 compose 项目：

```bash
for n in 0 1; do
  CRAWL_CPUSET=$(cat /sys/devices/system/node/node$n/cpulist) CRAWL_REPLICAS=2 \
  CRAWL_PORTS=808$((2 * n + 1))-808$((2 * n + 2)) \
    docker compose -f service/compose.yaml -p crawl-node$n --profile multi up -d crawl-multi
done
```

每个项目各有一个 `crawl-data` 卷，没问题：session 本来就是每副本各自的；历史则只在同一个项目的副本之间共享查询。

### 内存

按抓的页面估算每个槽位的引擎内存：

| 页面 | 每槽位引擎内存 | 每个忙碌槽位的 CPU |
|---|---|---|
| 小页面（约 35 KB，一个脚本一个样式表） | 约 20 MB | 约 1 核 |
| 重页面（约 400 KB 的维基百科文章，吃 CPU） | 约 85 MB | 约 1 核 |

例：16 槽位抓小页面约 0.3 GB，抓重页面约 1.4 GB，再加 Node 进程和余量。实测 16 槽位、混合负载、
`--cpus 24` 时引擎 RSS 平均约 940 MB（781–1,179 MB），空闲 10 分钟后回落到约 300 MB；内存随时间不增长。

引擎默认用 **jemalloc**（`LP_MALLOC=jemalloc`，镜像默认，不用改）。glibc 的 malloc 会攥着忙时释放的内存：同样的混合负载
glibc 约 2.1 GB、空闲后还有 1.5 GB，jemalloc 不到一半且基本都还回去；64 连接钉在一个 NUMA 节点时 glibc
每秒 3,735 个小页面，jemalloc 4,945 个。

## 测试

在 Docker 主机上对镜像跑端到端测试（会起容器、测试代理和测试页面，结束后清理）：

```bash
service/test/docker-test.sh lp-crawl      # NAME、PORT、TEST_PROXY_BASE 可用环境变量覆盖
node service/test/unit.mjs                 # 不需要引擎的单元测试
```

覆盖四种输出、跳转、404、脚本异常、参数错误、超时与部分结果、并发排队、代理与代理池（轮询、重试、剔除、
密码）、session（跨请求、并发合并、重启、删除、过期）、引擎被杀与恢复、请求历史（字段、代理打码、筛选、
过期清理、重启后保留）、管理页可访问且无外部资源、session 列表；MCP（进程命令行带 `--no-webmcp` 且没有
暴露机器人的参数、页面里没有 WebMCP 的三个名字、链接型和 ajax 型翻页点到底、两个并发会话互不等待互不串页、
cookie 隔离、`MCP_PROXY` 带密码生效、会话工具被拒、400/404/405、会话列表、历史字段和筛选、杀掉 MCP 进程后
会话 404 且能新建、DELETE；`session_id`：`/crawl` 登录的 HttpOnly cookie 带进 MCP、MCP 里登录后会话未结束
`/crawl` 就已登录、绑不同 session 互不串、不绑的没有 cookie、DELETE 写回最后一次调用之后的 cookie、历史按
session_id 同时查到两种行；MCP 开着时 `/crawl` 登录和登出下一步就生效、两个 MCP 会话绑同一个 session 互相看到
登录和登出、`docker stop` 时写回最后一次调用之后的 cookie）；停机（`docker stop` 时 `/crawl` 在飞：3 秒的请求拿到
完整结果、超过上限的被放弃并带回部分结果、排队的和新发的立刻 503、`/health` 503、历史里每个都有一行、同时开着的
MCP 会话照样写回 cookie、10 秒内退出码 0、引擎在自己的进程组）；`/crawl` 的两种翻页写法。2026-10-22 在 bt 上 105 项
全部通过。单元测试另有 MCP 网关的路由、会话、过期、历史、cookie 带入/写回/合并/拉入/冲突和停服务写回
（假引擎，不需要 Docker）。
