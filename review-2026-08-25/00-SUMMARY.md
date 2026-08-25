# 九角色评审汇总与修复分发（2026-08-25）

基线 commit：5db5d17 · 三份子报告：security.md / backend.md / frontend-ops.md

## 统计
| 报告 | P0 | P1 | P2 |
|---|---|---|---|
| security.md | 0 | 3 | 11 |
| backend.md | 1 | 6 | 13 |
| frontend-ops.md | 0 | 9 | 8 |

## P0（必须修）
- B1 [backend#1] 客户端正常断开时 turn 任务不取消 → 代理 run 失控继续执行（server.py:1447 break 路径跳过清理）

## P1 修复清单（按职责分组）
### 安全组（S）
- S1 [security#1 + F3] XSS：summonPanel embedURL/title 未转义；refreshSkills/Jobs/Machines 三处 innerHTML 直插
- S2 [security#2 + B#11] 音频缓冲无上限 OOM
- S3 [security#3 = backend#10] dash WS 未配 token 时 fail-open

### 后端组（B）
- B2 [backend#2] _STATE_LOCK 持锁跨网络请求
- B3 [backend#3] 状态文件非原子写
- B4 [backend#4] summon 广播与语音并发写同一 WS
- B5 [backend#5] tts_request_start 打点时机失真
- B6 [backend#6] SENTENCE_RE 域名/扩展名仍被切断
- B7 [backend#7] approval_decision 无异常兜底，断连

### 前端/运维组（F/O/C）
- F1 [frontend#F1] WS 重连无退避
- F2 [frontend#F2] checkAuth catch fail-open
- F4 [frontend#F4] 未认证时 boot 动画误导
- O1 [O1] 健康检查缺 -f，假绿
- O2 [O2] WS 矩阵跑两遍且 token 缺失静默通过
- O4 [O4] stop.sh pkill -if 误杀跨项目进程
- O5 [O5] launchd 日志无限增长
- C1 [C1] CI 测的是复制粘贴的 _proxy_allowed

## P2 择要（本轮修低成本的）
- 常量时间 token 比较（hmac.compare_digest）
- SSE 流中途断开检测（无 completed 即报错）
- 远程 STT 静默降级至少打日志+记 timing.errors
- 双 stop 并发重复 turn
- psutil cpu_percent(interval=0.1) 阻塞 loop
- F6 清屏后 liveEl 失联、F5 cookie Secure 条件化
- latency.jsonl 落盘前过 SECRET_RES

## 明确不修（记录理由）
- WS token query 参数：客户端兼容需要，文档标注
- /api/machines、/api/usage 公开：设计如此（HUD 未登录页依赖 usage），保持现状
- HUD 静态目录公开：模型文件非机密，README 标注即可
- history_turns 死配置：anthropic fallback 属应急路径，暂不动
- STT worker fail-open：worker 在独立 GPU 机，部署形态由用户控制，README 标注
