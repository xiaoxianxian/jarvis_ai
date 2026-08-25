# JARVIS 面具动画效果验收文档

## 需求
把贾维斯的静态面具改成：
1. 眼睛会自然眨眼
2. 倾听时微微侧身
3. 说话时嘴巴动

## 实现方案

### CSS 层 (server/hud/index.html L259-277)
```css
/* 两只发光眼睛 overlay */
.eye{
  width:14%; aspect-ratio:2.5/1;
  border-radius:50%;
  background: radial-gradient(ellipse,white 0%, cyan 42%, transparent 76%);
  box-shadow: glow effect;
  transform-origin:center; transform:scaleY(1);
  transition:transform 70ms ease-out;
}
.eye.l {left:26%; top:21%}  /* 左眼位置 */
.eye.r {right:26%; top:21%} /* 右眼位置 */
.eye.blink {transform:scaleY(.06)}  /* 眨眼动画 */

/* 嘴部面板 overlay */
.mouth-panel{
  left:42%; right:42%; top:49.5%; height:3.2%;
  border-radius:4px;
  background:rgba(cyan,.12);
  box-shadow: glow effect;
  transform-origin:center; transform:scaleY(1);
}
```

### HTML 层 (server/hud/index.html L382-390)
```html
<div class="character-overlay">
  <div class="eye l"></div>
  <div class="eye r"></div>
  <div class="mouth-panel"></div>
</div>
```

### JavaScript 层 (server/hud/index.html L1080-1120)

#### 眨眼循环
```javascript
function scheduleBlink() {
  // 每 2.5-6.5 秒随机眨眼一次
  // 眨眼持续时间 80-140ms
  const dur = 80 + Math.random()*60;
  document.querySelectorAll('.eye').forEach(e => e.classList.add('blink'));
  setTimeout(() => document.querySelectorAll('.eye').forEach(e => e.classList.remove('blink')), dur);
  setTimeout(scheduleBlink, 2500 + Math.random()*4000);
}
scheduleBlink();
```

#### 状态驱动侧身
```javascript
const stateTilts = {
  listening: 0.025,   // 倾听时向右微侧
  thinking: -0.018,   // 思考时向左微侧
  tool: 0.022,        // 工作中向右微侧
  speaking: 0,        // 说话时正面
  standby: 0,
  error: 0
};
// 监听 jarvisState 变化，平滑过渡
rig.style.transform = `perspective(800px) rotateY(${t*100}deg)`;
rig.style.transition = 'transform .45s ease-out';
```

#### 嘴部动效（RMS 驱动）
```javascript
// 每帧读取 speechAnalyser 的 RMS 值
const rms = Math.sqrt(sum / buf.length);
// speaking 状态基础开口 1.4，其他状态 1.0
const base = st === 'speaking' ? 1.4 : 1.0;
const open = Math.min(3.2, base + rms * 12);
mouth.style.transform = `scaleY(${open})`;
```

## 验证结果

### 自动眨眼
✅ 浏览器验证通过：2 eyes, 1 mouths 元素存在
✅ 眨眼功能正常运行：blinking 状态检测到

### E2E 语音通话
✅ E2E 测试通过："收到，贾维斯。面具效果看起来很有酷"
✅ Latency: 11.5s (eos→first_audio), 19.2s (total)

### 兼容性
✅ prefers-reduced-motion 降级：眨眼和侧身被禁用，嘴巴仍然响应

## 验收步骤

### 手动验收（浏览器）
1. 打开 `http://localhost:8765/hud/`
2. 观察面具：
   - 等待 3-7 秒，看到眼睛自然眨眼
   - 点击麦克风或按空格开始对话
   - 说话时观察嘴巴随音频开合
   - 倾听时观察面具微微侧身
   - 回答时嘴巴动效明显

### 自动化验收（脚本）
```bash
cd ~/jarvis-ai
bash server/scripts/jarvis-full-test.sh
# 预期输出: PASS=22 FAIL=0
```

### 视觉验收检查点
| 检查项 | 预期行为 | 状态 |
|--------|----------|------|
| 眨眼间隔 | 2.5-6.5 秒随机 | ✅ |
| 眨眼时长 | 80-140ms 快速闭合 | ✅ |
| 倾听侧身 | 向右微侧 ~2.5° | ✅ |
| 思考侧身 | 向左微侧 ~1.8° | ✅ |
| 说话正面 | 无侧身 | ✅ |
| 嘴巴开口 | 随音频 RMS 变化 | ✅ |
| 开口上限 | scaleY ≤ 3.2 | ✅ |
| 过渡动画 | 450ms ease-out | ✅ |

## 代码变更文件
- `server/hud/index.html` - CSS overlay + JS blink/mouth loop
- `server/server.py` - 无需修改（复用现有 window.speechAnalyser）

## 技术细节

### 位置校准
基于 `jarvis-character.png` (1024×1536) 像素扫描：
- 眼睛区域：y ≈ 19-31% 高度
- 嘴巴区域：y ≈ 49-51% 高度
- 实际 overlay 位置：eyes top=21%, mouth top=49.5%

### 性能
- 眨眼：setTimeout 异步调度，不占用动画帧
- 嘴巴：requestAnimationFrame 驱动，与 voiceLoop 同步
- 侧身：仅在 state 变化时触发 CSS transition

## 遗留事项（可选优化）
- [ ] 眼球可追踪光标位置（当前为静态位置）
- [ ] 嘴巴可添加多段式（上唇/下唇独立）
- [ ] 眨眼可添加"双眨眼"随机变体
- [ ] 侧身角度可根据语音来源方向调整

## 验收结论
✅ **通过** - 所有核心需求已实现并通过验证
