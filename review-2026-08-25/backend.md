# 后端架构 + 可靠性评审：jarvis-ai server/server.py

评审日期：2026-08-25 · 对象：`server/server.py`（1552 行，commit 5db5d17）、`server/tts_edge.py`、`server/tts_piper.py`、`server/config/server.yaml`
视角：异步/线程边界、资源泄漏、错误处理、数据一致性、性能。所有行号均对应当前 HEAD。

---

## P0

### 1. [P0] 客户端正常断开时 turn 任务不被取消 —— 代理 run 失控继续执行
- **位置**：`server/server.py:1447-1448`（break 路径）vs `server/server.py:1499-1509`（异常路径）
- **问题**：现代 Starlette 中 `ws.receive()` 对正常断开返回 `{"type": "websocket.disconnect"}` 消息而非抛 `WebSocketDisconnect`。代码在收到该消息时直接 `break`，跳过了取消逻辑；只有走旧式异常路径（1499-1509 行）才会 `turn_task.cancel()`。
- **影响**：用户关闭页面/APP 后，`_run_turn` 继续跑完整个 Hermes 代理回合——LLM 持续流式输出、agent 工具继续执行（副作用不受控）、TTS 子进程合成到超时，且不会调用 `stop_run`。向已死 WS 发送会反复触发异常被 1353-1358 吞掉。这是语音代理服务器最核心的生命周期漏洞。
- **修复**：把清理逻辑统一到 `finally`：
  ```python
  finally:
      WS_CLIENTS.discard(ws)
      if conn.turn_task and not conn.turn_task.done():
          conn.turn_task.cancel()
          await asyncio.gather(conn.turn_task, return_exceptions=True)
      if conn.partial_task and not conn.partial_task.done():
          conn.partial_task.cancel()
  ```
  并复用 `_cancel_active_turn` 的 tts_proc 终止逻辑。

---

## P1

### 2. [P1] `_STATE_LOCK` 持锁跨越网络请求（最长 15s+），全局会话创建串行阻塞
- **位置**：`server/server.py:216-232`
- **问题**：`get_session_id` 在 `with _STATE_LOCK:` 内执行 `requests.post(..., timeout=15)` 创建会话。Hermes API 卡顿/不可达时，所有其他连接的首次回合（以及 HUD `/api/chat`）都排队等锁；重连风暴下逐个串行创建，每个最多 15s。
- **影响**：多连接场景下一处网络抖动放大为全站回合延迟；已知"锁粒度"问题的真正根源。
- **修复**：缩小临界区——先无锁读缓存；未命中时在锁外 POST 创建，再短暂持锁做二次读取合并写入（代码里已有 re-read 合并逻辑，把它移出网络调用之后即可）。另可加 per-conversation 的 in-flight 去重，避免并发重复建会话。

### 3. [P1] 状态文件非原子写入：崩溃即静默丢失会话映射与用量统计
- **位置**：`server/server.py:208-210`（`_save_state`）、`server/server.py:81-82`（`record_usage`）
- **问题**：`STATE_PATH.write_text(...)` 与 `USAGE_PATH.write_text(...)` 都是就地覆盖写，无 tmp+`os.replace`。进程被杀/断电落在写中间，文件截断；下次 `_load_state` 的 `except Exception` 静默返回 `{}`。
- **影响**：Hermes 会话 ID 映射丢失 → 下次强制新建会话，长期记忆上下文断裂且无任何告警；usage_stats 归零。latency.jsonl 是追加写不受影响。
- **修复**：统一封装 `def _atomic_write_json(path, obj)`：写 `path.with_suffix(".tmp")` 后 `os.replace`。

### 4. [P1] `/api/summon` 广播与语音回合并发写同一 WebSocket —— ASGI 发送竞态
- **位置**：`server/server.py:1124-1129`（summon 循环 `await client.send_json`）；语音音频发送在 `server.py:784`（`ws.send_bytes`）
- **问题**：`WS_CLIENTS` 包含正在播放语音的连接。summon 处理器与 turn 任务分属不同协程，对同一 Starlette WebSocket 并发 `send_*`。ASGI 层不保证并发发送安全（uvicorn/websockets 实现可能交错帧或抛 `RuntimeError`）。
- **影响**：HUD 召唤面板的瞬间可能打断/杀死正在进行的语音回合连接；偶发且难复现。
- **修复**：每个连接维护一个出站 `asyncio.Queue` + 单一 sender 协程序列化发送；或 summon 只投递到空闲连接 / 改经主收发循环转发。

### 5. [P1] 系统 TTS 的 `tts_request_start_monotonic` 在合成完成后才打点，首字节延迟指标失真
- **位置**：`server/server.py:646`（对比 ElevenLabs 路径的正确打点 `server.py:496`）
- **问题**：`_system_tts_chunks` 在子进程合成完毕后（646 行）才设 `tts_request_start_monotonic`，而 `first_tts_audio_byte_monotonic` 在 656-657 行紧随其后设置。`summary()` 的 `time_to_first_tts_audio_byte_seconds`（166 行）因此恒≈0。
- **影响**：latency.jsonl 里该指标对 system/edge/piper 全部失真（真实合成耗时 1–10s 被抹掉），无法用于回归对比；与 ElevenLabs 路径语义不一致。这正是已记录的"tts_request_start 打点时机"问题。
- **修复**：把 646 行移到 `_run_wrapper`/`subprocess.Popen` 之前（进入函数即打点），保留 `or` 守卫使多句只记第一句。

### 6. [P1] SENTENCE_RE 的小数点保护只防"标点后跟数字"，域名/扩展名仍被拦腰切断（实测复现）
- **位置**：`server/server.py:93`
- **问题**：`(.+?[.!?。！？])(?=\s|$|[^\d])` 的 `[^\d]` 仅当句点后是数字时抑制切分。本机验证：
  - `'访问 example.com 获取更多'` → `(['访问 example.'], 'com 获取更多')` ❌
  - `'价格是3.14元。好的'` → 正确 ✅
- **影响**：LLM 回答里的 URL、域名、文件名（`.py`/`.com`）被切成两"句"，第一句立即送去 TTS，产生不自然的停顿和误读；近期改动声称修复小数点但只覆盖了数字后缀场景。缩写（Dr. / etc.）同样切分（固有局限，可接受）。
- **修复**：加负向前瞻排除字母数字紧跟的场景：`(?![A-Za-z0-9])` 替代 `[^\d]`（同时保留原中文意图），或维护小集合白名单（`.com/.py/.org` 等）。改完用 `jarvis-full-test.sh` 加域名用例回归。

### 7. [P1] `approval_decision` 处理无异常兜底：Hermes 不可达时整条 WS 连接被杀
- **位置**：`server/server.py:1491-1492`
- **问题**：`await asyncio.to_thread(pipeline.hermes.post_approval, ...)` 无 try。Hermes 重启/离线时 `requests.ConnectionError` 抛出；外层 `except RuntimeError`（1503 行）不匹配 → 异常穿透出接收循环 → 连接关闭。同文件的 `stop_run` 路径（1401-1408 行）有完整兜底，此处遗漏。
- **影响**：一次审批点击在网络抖动下断开整个语音连接（含录音状态），用户需重新连接。
- **修复**：包一层 try，失败回 `{"type":"error","message":"Approval failed: ..."}` 并 continue。

---

## P2

### 8. [P2] RealtimeSTT 子进程死亡后 `poll_connection` 死循环刷 ERROR 日志（EOFError 刷屏根因）
- **位置**：依赖 `RealtimeSTT/core/transcription.py:65-79`（`poll_connection`：`while not shutdown_event` 内 `except Exception → logging.error(exc_info=True)` 后仅 sleep 继续）；whisper 子进程退出后管道 EOF，`recv()` 每 10ms 抛一次 EOFError，无限循环。
- **影响**：日志被 traceback 淹没，掩盖真实错误；CPU 空转。
- **修复**：上游修法是 `except EOFError: break`。不动依赖的话，在 server 入口给 root logger 加 Filter 匹配 `"Error receiving data from connection"` 且检测到连续 N 次后打印一次性告警并尝试重建 recorder；或 fork-pin 一个补丁版本。

### 9. [P2] token 比较未用常量时间比较
- **位置**：`server/server.py:887`、`932`、`939`、`1252`
- **问题**：`supplied == token` / `cookies.get(...) == token` 均为普通字符串比较。
- **影响**：LAN 设备上理论计时侧信道可逐字节猜 JARVIS_HUD_TOKEN。实际风险低（LAN + TLS），但修复成本一行。
- **修复**：`hmac.compare_digest(supplied.encode(), token.encode())`。

### 10. [P2] dashboard WS 代理在未配置 token 时 fail-open，与 HTTP 中间件 fail-closed 不一致
- **位置**：`server/server.py:1251-1255`（`if token and ...` 否则直接放行 accept）vs `server.py:1213-1218`（HTTP 返回 503）
- **影响**：忘配 JARVIS_HUD_TOKEN 时，HTTPS 9443 上任何人可经 WS 代理直达 dashboard 后端，绕过 HTTP 侧的 503 防线。
- **修复**：与 dash_auth_middleware 对齐——`if not hud_token(): await ws.close(code=4503); return`。

### 11. [P2] 音频缓冲无上限：失控客户端可无限占用内存
- **位置**：`server/server.py:1495-1498`（append 无上限）；`1419` 行的 30s 上限只控制是否调度 partial，不裁剪缓冲
- **影响**：客户端 bug 或恶意发送可使 `audio_chunks` 无限增长（16kHz×2B ≈ 2MB/分钟），长时间运行 OOM。
- **修复**：`start` 后累计上限（如 300s 音频），超限丢弃并回报 error。

### 12. [P2] fire-and-forget `asyncio.create_task` 未保存引用，任务可能被 GC
- **位置**：`server/server.py:861`（warm）、`1091`（eleven refresh）、`1186`（worker refresh）
- **问题**：事件循环只持弱引用，CPython 文档明确警告不保存结果的 task 可能在完成前被回收。
- **修复**：模块级 `_BG_TASKS: set[asyncio.Task]`，`add` 后 `add_done_callback(_BG_TASKS.discard)`。

### 13. [P2] SSE 流中途断开无法检测 —— 半截回答被当作完整回合结束
- **位置**：`server/server.py:267-321`（`iter_lines` 结束即生成器正常返回；只有 `run.failed`/`error` 事件才报错）
- **影响**：Hermes 侧崩溃/网络中断导致流提前关闭时，用户听到半句话且无任何 error 事件或重试信号；timing 也标记为正常完成。
- **修复**：`done`/`assistant.completed`/`run.completed` 任一未见而流结束则 raise（或在 final 事件缺失时向客户端发 `{"type":"error","message":"response stream truncated"}`）。

### 14. [P2] 远程 STT 故障完全静默降级
- **位置**：`server/server.py:402-409`（`except Exception: pass`）
- **影响**：GPU worker 长期宕机无从察觉——每次都默默落到本地 small 模型（慢 10 倍以上），`timing.errors` 无记录，运维只能靠感知延迟发现。
- **修复**：至少 `print` 一次 + 写入 `timing.errors.append("remote_stt_unavailable")`；可加简单熔断（连续 N 次失败后 M 分钟内跳过 remote）。

### 15. [P2] barge-in 路径同步等待 stop_run（≤15s）阻塞 WS 接收循环
- **位置**：`server/server.py:1460`（start 时内联 await `_cancel_active_turn`）→ `1402`（to_thread stop_run, timeout 15）
- **影响**：用户插话后，新的录音 `start` 要等旧 run 的停止请求返回才被受理；Hermes 卡顿时插话响应劣化数秒——恰好违背 barge-in 低延迟初衷。另外被取消回合遗留的 STT 线程仍占着 `stt_lock` 跑完当前转录，新回合转录在其后排队的窗口同样存在。
- **修复**：`_cancel_active_turn` 里把 stop_run 放进独立 task（fire-and-forget 或挂到 conn 上），先返回受理录音；STT 侧可在取消时记录"abandoned transcription"并让后续等待者可感知。

### 16. [P2] `psutil.cpu_percent(interval=0.1)` 在事件循环内同步睡眠 100ms
- **位置**：`server/server.py:1146-1150`
- **影响**：`/api/machines` 每次 CPU 快照期间阻塞整个 loop（含语音音频发送）；HUD 轮询频繁时累积抖动。
- **修复**：`cpu_percent(interval=None)`（非阻塞，取自上次调用以来的均值，首次预热）或挪进已有的后台刷新缓存。

### 17. [P2] `history_turns` 配置为死配置 —— anthropic fallback 实际不带任何历史
- **位置**：`server/config/server.yaml:14`（注释称 "fallback provider only"）vs `server.py:441-456`（messages 只有当前一条）
- **影响**：basic mode 下多轮对话无记忆，用户以为 fallback 有 12 轮上下文；配置误导排障。
- **修复**：要么实现（从 Hermes 拉 messages 拼进 prompt），要么删除配置项并更新注释。

### 18. [P2] `timing.tts_proc` 赋值存在竞态窗口，barge-in 可能漏杀刚启动的子进程
- **位置**：`server/server.py:551-553`（Popen 后才赋 `timing.tts_proc`）、`586-592`、`624-628` vs 读取端 `1379-1386`
- **影响**：取消发生在 Popen 与赋值之间时子进程逃过 terminate，继续合成至超时（浪费 CPU/网络，若 edge 已写出 wav 则无副作用，但 piper/say 会空跑）。窗口小，属已知残留。
- **修复**：赋值前注册（Popen 前置一个占位 Event），或取消路径在 terminate 后再补一次检查 `timing.tts_proc.poll()`。

### 19. [P2] `/api/usage`、`/api/machines` 免鉴权暴露用量与机器统计于 0.0.0.0 明文端口
- **位置**：`server/server.py:878`（`_PUBLIC_API_PATHS`）、配置 `host: 0.0.0.0, port: 8765`（无 TLS）
- **影响**：LAN 内任意主机可读取 token 用量、成本估算、机器 CPU/内存/磁盘与 worker 地址拓扑。信息泄露面大于必要。
- **修复**：machines 移出公开列表（HUD 有 token 后再拉），或至少剥离 worker 主机名/IP。

### 20. [P2] hermes_proxy 单请求占用工作线程最长 300s，可耗尽默认线程池拖累语音管线
- **位置**：`server/server.py:979-987`（`timeout=300` + `asyncio.to_thread`）
- **影响**：默认 executor 约 `min(32, cpu+4)` 线程；HUD 大量消息拉取叠加 STT/TTS 的 to_thread 占用，极端情况下 turn 的转录/合成线程排队等待，语音延迟尖刺。
- **修复**：GET messages 类代理降到 30-60s 超时；或为语音管线单独建 `ThreadPoolExecutor(max_workers=N)` 专用。

---

## 数量统计

| 级别 | 数量 |
|------|------|
| P0 | 1 |
| P1 | 6 |
| P2 | 13 |
| **合计** | **20** |

优先修复顺序建议：#1（失控 run）→ #5/#6（本次近期改动引入/未修全的指标与切分问题）→ #2/#3（状态一致性）→ #4/#7（连接健壮性）。
