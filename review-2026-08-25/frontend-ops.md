# jarvis-ai 前端 UX + 运维 CI 评审（2026-08-25）

范围：`server/hud/index.html`（1085 行单文件）、`server/scripts/jarvis-{full-test,start,stop,restart}.sh`、`.github/workflows/ci.yml`、`launchd/*.plist`。
每条含严重级别、位置、问题、影响、修复建议。仅列经代码核实的问题。

---

## 一、前端健壮性 / UX（server/hud/index.html）

### F1 [P1] WS 重连无退避、无上限，构成重连风暴
- **位置**：`server/hud/index.html:516`
- **问题**：`ws.onclose` 固定 `setTimeout(connect, 3000)` 无条件重连，无指数退避、无抖动、无最大次数、页面隐藏时也不暂停。
- **影响**：服务端重启或网络中断期间，每个打开的 HUD 标签每 3 秒打一次握手；多设备/多标签叠加形成同步重连风暴，服务端恢复瞬间被 SYN/upgrade 洪峰冲击；且永远重试，服务端长期下线时客户端静默空转。
- **建议**：退避 `delay = min(30000, 3000 * 2^n) ± jitter`，成功后归零；`document.hidden` 时暂停或拉长间隔；连续 N 次失败后在 UI 给出「服务离线，点击重试」而不是无限自旋。

### F2 [P1] `checkAuth()` 失败时 fail-open，导致未认证也进入连接/轮询循环
- **位置**：`server/hud/index.html:897-903`（`catch{}` 返回 `true`）、`:803-806`（轮询定时器无条件启动）
- **问题**：`/api/auth/check` 网络异常（服务器刚启动、代理抖动）时 `catch` 吞掉错误并返回 true → 直接 `connect()`；同时 `refreshHealth/Skills/Jobs/Machines/Usage` 五个定时器在未登录时照常启动。
- **影响**：与近期修复的意图相悖——认证检查失败（而非返回 401）时仍会连 WS，被服务端 fail-closed 拒绝后进入 F1 的无限重连；未登录时每 10–120 秒持续打 5 个必 401 的接口。
- **建议**：`catch` 时区分网络错误与 401：网络错误应提示并稍后重查，而非放行；轮询定时器在 `checkAuth` 通过后再启动，401 响应时统一停止。

### F3 [P1] 多处把服务端数据未经转义写入 innerHTML
- **位置**：
  - `server/hud/index.html:756`（`refreshSkills`：`x.name||x` 直插）
  - `server/hud/index.html:762-764`（`refreshJobs`：`x.name||x.prompt` 直插）
  - `server/hud/index.html:778`（`refreshMachines`：`m.name`、`m.note` 直插）
  - `server/hud/index.html:857-866`（`summonPanel`：`title` 未转义直插 `.holoBar`）
- **问题**：`addMsg`/`addActivity`/`showApproval` 都正确做了转义或用 `textContent`，但技能名、任务名、机器名、全息面板标题这条数据链路没有。这些字段来自 Hermes 会话/配置，任何能把含 HTML 的字符串写进技能名或 prompt 的路径都能注入脚本。
- **影响**：存储型 XSS：HUD 持有 `jarvis_token` cookie（一年有效期），注入脚本可读取/发起任意代理请求。
- **建议**：复用现成的 `esc()`（:475 已有同样实现，抽成公共函数），对四个插入点统一转义；`title` 同理。

### F4 [P1] boot 动画在未认证时照常播放，宣称「所有系统就绪」误导用户
- **位置**：`server/hud/index.html:982`（无条件调用）、`:922-927`（boot 文案「语音链路已建立」「所有系统就绪」）
- **问题**：`bootSequence()` 在页面加载即执行，PIN 门（z-index 200）盖在 boot（z-index 100）之上，但用户先看到的是一整套「系统就绪」的启动日志，随后才发现要输密码。
- **影响**：新用户/换设备访问时 boot 承诺与现实矛盾；且 boot 期间的「语音链路已建立」是假状态（此时 WS 尚未连接甚至未认证）。
- **建议**：把 `bootSequence` 放进 `checkAuth().then(ok=>{ if(ok) bootSequence(...) })` 链；未认证时显示精简的「等待验证」画面而非全套就绪文案。

### F5 [P2] PIN cookie 带 `Secure`，HTTP 访问时陷入无提示的死循环
- **位置**：`server/hud/index.html:910`
- **问题**：cookie 固定 `secure` 标志。若用户通过纯 HTTP（如局域网 `http://<ip>:8765` 或未来去掉 TLS 的入口）访问，浏览器丢弃该 cookie，`/api/auth/check` 永远 401，输入正确密码后 `location.reload()` 回到同一个门。
- **影响**：特定部署形态下 PIN 门完全不可用且无任何报错线索。
- **建议**：按 `location.protocol === 'https:'` 条件附加 `secure`；或在 PIN 门错误信息中检测协议并提示「当前为 HTTP，cookie 无法持久化」。

### F6 [P2] 「清屏」后 live 转写气泡写入已分离节点
- **位置**：`server/hud/index.html:484-487`（`liveEl` 缓存）、`:699/:705`（`feed.innerHTML=""`）
- **问题**：清屏/`/new` 用 `feed.innerHTML=""` 清空，但模块级 `liveEl` 引用未置空；下一次 `showLive()` 往已从 DOM 移除的节点写 `textContent`，实时转写从此不可见，直到下次 `clearLive()`+新消息。
- **影响**：语音输入时屏幕上不再出现正在说的话，用户以为麦克风没生效。
- **建议**：清屏时同时 `liveEl=null`；或 `showLive` 里检测 `!liveEl.isConnected` 则重建。

### F7 [P2] iOS Safari 聚焦输入框触发自动放大
- **位置**：`server/hud/index.html:74`（`#chatInput{font-size:15px}`）
- **问题**：iOS 在聚焦 font-size < 16px 的输入框时会自动缩放页面；`#chatInput` 为 15px（`#pinInput` 16px 恰好达标）。
- **影响**：移动端（已有 880px 断点适配）每次点聊天框页面被放大且不回弹，破坏布局。
- **建议**：`#chatInput` 提到 16px，或移动端媒体查询内加 `font-size:16px`。

---

## 二、运维脚本

### O1 [P1] 健康检查不带 `--fail`，任何 HTTP 状态都算通过
- **位置**：`server/scripts/jarvis-full-test.sh:37-41`
- **问题**：`curl -s -m 3 … -o /dev/null && ok` 只看 curl 退出码；500/404/502 同样让 curl 返回 0。
- **影响**：「voice ws :8765 ✓」可能只是服务端在报错但端口活着——这正是全量测试要抓的问题，属于系统性误报（假绿）。
- **建议**：加 `-f`（fail on HTTP error）并用 `-w '%{http_code}'` 断言 200，与第 3 节的写法保持一致。

### O2 [P1] 第 4 节 WS 矩阵完整跑了两遍，第一遍结果不计分；token 缺失时整节静默通过
- **位置**：`server/scripts/jarvis-full-test.sh:58-81`（直接打印、不计分）、`:87-107`（同一矩阵复制一份喂给 `while read` 计分）；`:61/:90` 及 `:26` 从 `~/.hermes/.env` 提取 token
- **问题**：(a) 两段几乎相同的 Python 各跑一次，第一段的 `WS-BAD-TOKEN` 等输出完全不进 PASS/FAIL，纯属双倍耗时且两份代码会漂移；(b) 若 `~/.hermes/.env` 不存在或缺该行，Python 抛 IndexError，heredoc 输出为空，`while read` 读不到任何行 → 5 个 WS 检查一个都不计分，脚本照样 `PASS=x FAIL=0` 绿色退出（`:26` 的 `TOKEN` 同理为空串，第 3 节用空 token 测出的是 401 假阴性）。
- **影响**：安全关键路径（bad-token 必须被拒）在最需要它的机器上可能根本没被执行。
- **建议**：删除第一段（:58-81）；提取 token 后立即校验非空（`[ -n "$TOKEN" ] || { bad "token missing"; }`），WS Python 块失败时输出哨兵行使检查显式变红。

### O3 [P2] 全量测试收尾按端口杀进程，可能误杀抢占者
- **位置**：`server/scripts/jarvis-full-test.sh:128`；配合 `:18`（固定写 `/tmp/jarvis_fulltest.log`）
- **问题**：`kill $(lsof -t -iTCP:8765 …)` 杀的是「当前占用 8765 的任何进程」。若临时 server 启动失败、端口被无关进程抢到，会把别人的进程杀掉；日志固定写 `/tmp` 同一路径，并发运行互相覆盖。
- **建议**：记录自己 spawn 的 PID（`$!`）只杀它；日志文件名带 `$$`。

### O4 [P1] `jarvis-stop.sh` 的 `pkill -9 -if "server\.py"` 与按端口 443 无差别 kill -9
- **位置**：`server/scripts/jarvis-stop.sh:11-14`
- **问题**：`pkill -9 -if "server\.py"` 匹配命令行含 `server.py` 的**任何**进程——本机其他项目的 `foo/server.py` 一并被杀，且是 SIGKILL（无清理机会）；循环里还包含 `port 443`，本机若有其他服务监听 443 同样被 `kill -9`。
- **影响**：跨项目误杀 + 强杀导致子进程/临时文件无人收拾；这也是注释里「orphaned STT children」问题的成因之一（先用 KILL 就不会有优雅退出）。
- **建议**：缩小匹配面（如 `pkill -9 -if "$REPO_ROOT.*server\.py"` 或先 `pgrep -fl` 核对 cwd）；443 从端口列表移除或仅在确认属主时杀；优先 TERM、宽限数秒后再 KILL。

### O5 [P1] launchd 日志单文件无限增长，仓库内无任何轮转配置
- **位置**：`launchd/com.jarvis.voice.plist:23-24`、`launchd/com.jarvis.dashboard.plist:13-14`（stdout+stderr 写同一文件）；`KeepAlive=true`（两份 plist）常驻运行
- **问题**：语音服务常驻且逐轮打印转写/计时，日志只增不减；仓库中没有 newsyslog 配置、也没有脚本内轮转。
- **影响**：数月后磁盘被单文件吃满，且 stdout/stderr 交织在同一条记录里难以排查。
- **建议**：提供 `newsyslog.d/jarvis.conf`（`logpath size=10M count=5` 之类）随安装脚本部署，或 plist 改指向管道脚本按日切割；stdout/stderr 分文件。

### O6 [P2] `jarvis-start.sh` 吞错并无条件宣告成功；restart 存在 launchd 竞态窗口
- **位置**：`server/scripts/jarvis-start.sh:8-15`、`server/scripts/jarvis-restart.sh:1`
- **问题**：`gateway start/install || true` 与 `bootstrap || kickstart` 的失败全部静默，最后无条件 `echo started`；plist 缺失时两个分支都失败也无感知。restart 中 `bootout` 后固定 `sleep 3` 再 start，若 bootout 未完成，`bootstrap` 报 EBUSY 走 `kickstart` 分支操作的是刚被卸载的服务，同样静默失败。
- **影响**：「started」不可信，故障要到打开 HUD 才发现。
- **建议**：start 末尾加端口探活（复用 O1 修好的 curl 断言，失败则非零退出）；restart 用 `bootout` 的返回/`launchctl print` 轮询替代死等 3 秒。

---

## 三、CI（.github/workflows/ci.yml）

### C1 [P1] 安全用例测的是复制粘贴的 `_proxy_allowed`，不是线上真代码
- **位置**：`.github/workflows/ci.yml:49-90`
- **问题**：路径穿越白名单的 11 个断言针对 workflow 内联重新实现的函数；`server/server.py` 里的真实实现改了逻辑（新增放行路径、改 normpath 方式）CI 完全不知情。
- **影响**：最关键的防穿越回归检测形同虚设——测试永远绿，防护却可能已经破了。
- **建议**：从 `server/server.py` 导入真实判定函数（沿用现有的 `sys.modules` stub 手法挡掉 RealtimeSTT 等重依赖），用例只保留数据表。

### C2 [P2] py_compile 白名单硬编码，新增源码不在覆盖内
- **位置**：`.github/workflows/ci.yml:19-29`
- **问题**：逐个列出 8 个文件；`client/`、worker 新增模块、scripts 下新 .py 都不会编译检查。
- **建议**：改 `python3 -m compileall -q server worker client hermes-plugin`（排除 venv）。

### C3 [P2] 对运维核心的 shell 只有 `bash -n`，前端 1000 行内联 JS 零检查
- **位置**：`.github/workflows/ci.yml:31-33`（仅语法）；index.html 的 JS 无任何 lint
- **问题**：`bash -n` 只验语法，查不出 O1/O2/O4 这类逻辑缺陷（shellcheck 能命中大部分）；HUD 单文件的 JS 出错只能靠人肉或线上发现。
- **建议**：加 shellcheck step（`apt install shellcheck` 或官方 action）；JS 至少用 `node --check` 抽出 `<script>` 内容做语法校验，或引 eslint 快速版。

### C4 [P2] requirements.txt「sanity」只数行数 ≥ 10
- **位置**：`.github/workflows/ci.yml:92-98`
- **问题**：断言与可安装性零相关——重复行、注释凑数、版本冲突都通过。
- **建议**：改为真实安装冒烟：建 venv `pip install -r server/requirements.txt --dry-run`（或装轻量子集）+ `pip check`。

---

## 统计

| 级别 | 数量 | 编号 |
|---|---|---|
| P0 | 0 | — |
| P1 | 9 | F1 F2 F3 F4 O1 O2 O4 O5 C1 |
| P2 | 8 | F5 F6 F7 O3 O6 C2 C3 C4 |
| 合计 | 17 | |

说明：未发现可直接远程利用的 P0（XSS 数据源为本机服务端，攻击前提是已能写入 Hermes 数据）。优先级最高的三件事：修 O2（全量测试可能在关键机器上假绿）、C1（安全测试与实现脱钩）、F3（补齐四处 innerHTML 转义）。
