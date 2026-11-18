// @local/dsh-vmouse-mcp - MCP stdio server for the agent's own virtual mouse.
//
// The heavy lifting lives in vmouse.ps1: a resident STA PowerShell process that
// paints a click-through, always-on-top cursor overlay and injects clicks as
// window messages, so the user's real pointer never moves.
//
// Protocol with vmouse.ps1: one base64(JSON) request per line on stdin, one JSON
// response per line on stdout.
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const helperPath = join(here, 'vmouse.ps1');

const POWERSHELL = 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';

let helper = null;
let seq = 0;
let buffer = '';
let stderrTail = '';
const waiting = new Map();

function startHelper() {
  if (helper) return helper;
  if (!existsSync(helperPath)) throw new Error(`vmouse.ps1 not found: ${helperPath}`);
  const ps = existsSync(POWERSHELL) ? POWERSHELL : 'powershell.exe';
  helper = spawn(ps, ['-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass', '-File', helperPath], {
    stdio: ['pipe', 'pipe', 'pipe'],
    windowsHide: true,
  });
  helper.stdout.setEncoding('utf8');
  helper.stdout.on('data', (chunk) => {
    buffer += chunk;
    let idx;
    while ((idx = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, idx).trim();
      buffer = buffer.slice(idx + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      if (msg.debug) continue;
      const waiter = waiting.get(msg.id);
      if (!waiter) continue;
      waiting.delete(msg.id);
      if (msg.ok) waiter.resolve(msg.result);
      else waiter.reject(new Error(msg.error || 'vmouse error'));
    }
  });
  helper.stderr.setEncoding('utf8');
  helper.stderr.on('data', (d) => {
    stderrTail = (stderrTail + String(d)).slice(-4000);
  });
  helper.on('exit', (code) => {
    helper = null;
    for (const waiter of waiting.values()) {
      waiter.reject(new Error(`vmouse process exited (code ${code})${stderrTail ? ': ' + stderrTail.trim().slice(-500) : ''}`));
    }
    waiting.clear();
  });
  helper.on('error', (e) => {
    helper = null;
    for (const waiter of waiting.values()) waiter.reject(e);
    waiting.clear();
  });
  return helper;
}

function call(cmd, args = {}, timeoutMs = 30000) {
  const h = startHelper();
  const id = ++seq;
  const payload = Buffer.from(JSON.stringify({ id, cmd, ...args }), 'utf8').toString('base64') + '\n';
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      waiting.delete(id);
      reject(new Error(`vmouse command '${cmd}' timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    waiting.set(id, {
      resolve: (v) => { clearTimeout(timer); resolve(v); },
      reject: (e) => { clearTimeout(timer); reject(e); },
    });
    try {
      h.stdin.write(payload);
    } catch (e) {
      clearTimeout(timer);
      waiting.delete(id);
      reject(e);
    }
  });
}

const text = (t) => ({ type: 'text', text: t });

const commonPoint = {
  x: { type: 'number', description: '屏幕 X 坐标（物理像素，全桌面左上角为 0,0；与 screen_capture 图像的像素坐标一致）' },
  y: { type: 'number', description: '屏幕 Y 坐标（物理像素）' },
};

const targetParams = {
  hwnd: { type: 'number', description: '可选：直接把消息投给这个窗口句柄（可点被遮挡的窗口）。默认投给坐标处最上面的窗口' },
  window: { type: 'string', description: '可选：按窗口标题包含的文字定位目标窗口，代替 hwnd' },
};

const tools = [
  {
    name: 'click',
    description:
      '在屏幕坐标处点击，使用窗口消息投递：不移动、不占用用户的真实鼠标指针（真实指针位置前后一致，响应里会返回 realBefore/realAfter 供核对）。' +
      '屏幕上会出现 agent 自己的光标图标和点击波纹。默认点坐标处最上面的窗口；先截图确认位置。' +
      '少数程序（游戏、原始输入、画布/自绘控件）只认物理输入，此时才传 real:true。',
    inputSchema: {
      type: 'object',
      properties: {
        ...commonPoint,
        button: { type: 'string', enum: ['left', 'right', 'middle'], description: '按键，默认 left' },
        clicks: { type: 'number', description: '点击次数，默认 1；2 表示双击' },
        real: { type: 'boolean', description: '默认 false（消息注入，不碰真实指针）。true 时短暂移动真实指针点完再复原，仅在消息注入无效时使用' },
        ...targetParams,
      },
      required: ['x', 'y'],
      additionalProperties: false,
    },
  },
  {
    name: 'move',
    description: '把 agent 的虚拟光标移动到屏幕坐标并短暂显示（会滑行 200ms），不移动真实鼠标指针。适合悬停、展示位置、确认坐标。',
    inputSchema: {
      type: 'object',
      properties: { ...commonPoint },
      required: ['x', 'y'],
      additionalProperties: false,
    },
  },
  {
    name: 'drag',
    description:
      '从 (from_x, from_y) 按住拖到 (to_x, to_y) 再松开，默认用窗口消息投递，不移动真实指针。用于拖动窗口、滑块、选择文本。',
    inputSchema: {
      type: 'object',
      properties: {
        from_x: { type: 'number', description: '起点屏幕 X' },
        from_y: { type: 'number', description: '起点屏幕 Y' },
        to_x: { type: 'number', description: '终点屏幕 X' },
        to_y: { type: 'number', description: '终点屏幕 Y' },
        button: { type: 'string', enum: ['left', 'right', 'middle'], description: '按键，默认 left' },
        real: { type: 'boolean', description: '默认 false；true 时短暂移动真实指针完成拖动再复原' },
      },
      required: ['from_x', 'from_y', 'to_x', 'to_y'],
      additionalProperties: false,
    },
  },
  {
    name: 'scroll',
    description: '在屏幕坐标处滚动滚轮（正数向上、负数向下，一格约 120），默认用窗口消息，不移动真实指针。',
    inputSchema: {
      type: 'object',
      properties: {
        ...commonPoint,
        delta_y: { type: 'number', description: '滚动量，正数向上、负数向下，一格约 120' },
        hwnd: { type: 'number', description: '可选：直接投递给这个窗口句柄' },
        window: { type: 'string', description: '可选：按窗口标题包含的文字定位目标窗口' },
      },
      required: ['x', 'y', 'delta_y'],
      additionalProperties: false,
    },
  },
  {
    name: 'status',
    description: '查询虚拟鼠标状态：浮层是否可见、虚拟光标坐标、真实指针坐标、最近一次操作。不会让光标出现。',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
];

function targetText(t) {
  if (!t) return '';
  const title = t.title ? `"${t.title}"` : '(无标题窗口)';
  return `${title} [${t.class}] pid ${t.pid}, hwnd ${t.hwnd}`;
}

async function callTool(params) {
  const name = params?.name;
  const args = params?.arguments ?? {};
  switch (name) {
    case 'click': {
      const r = await call('click', {
        x: Math.round(args.x),
        y: Math.round(args.y),
        button: args.button ?? 'left',
        clicks: args.clicks ?? 1,
        real: Boolean(args.real),
        ...(args.hwnd != null ? { hwnd: String(args.hwnd) } : {}),
        ...(args.window ? { window: String(args.window) } : {}),
      });
      const how = r.mode === 'real' ? '真实指针短暂移动后已复原' : 'window 消息注入，真实指针未移动';
      const tgt = r.target ? `\n目标窗口：${targetText(r.target)}（客户区坐标 ${r.target.clientX}, ${r.target.clientY}）` : '';
      return {
        content: [
          text(
            `已在 (${r.x}, ${r.y}) 用${r.button === 'right' ? '右键' : r.button === 'middle' ? '中键' : '左键'}点击 ${r.clicks} 次（${how}）。` +
              `\n真实指针：点击前 (${r.realBefore.x}, ${r.realBefore.y}) → 点击后 (${r.realAfter.x}, ${r.realAfter.y})${tgt}`,
          ),
        ],
      };
    }
    case 'move': {
      const r = await call('move', { x: Math.round(args.x), y: Math.round(args.y) });
      return { content: [text(`虚拟光标已移到 (${r.x}, ${r.y})；真实指针仍在 (${r.realX}, ${r.realY})，未移动。`)] };
    }
    case 'drag': {
      const r = await call('drag', {
        from_x: Math.round(args.from_x),
        from_y: Math.round(args.from_y),
        to_x: Math.round(args.to_x),
        to_y: Math.round(args.to_y),
        button: args.button ?? 'left',
        real: Boolean(args.real),
      }, 45000);
      const how = r.mode === 'real' ? '真实指针短暂移动后已复原' : 'window 消息注入，真实指针未移动';
      const tgt = r.target ? `\n目标窗口：${targetText(r.target)}` : '';
      return { content: [text(`已从 (${r.from.x}, ${r.from.y}) 拖到 (${r.to.x}, ${r.to.y})（${how}）。${tgt}`)] };
    }
    case 'scroll': {
      const r = await call('scroll', {
        x: Math.round(args.x),
        y: Math.round(args.y),
        delta_y: Math.round(args.delta_y),
        ...(args.hwnd != null ? { hwnd: String(args.hwnd) } : {}),
        ...(args.window ? { window: String(args.window) } : {}),
      });
      return { content: [text(`已在 (${r.x}, ${r.y}) 滚动 ${r.delta_y}；真实指针仍在 (${r.realAfter.x}, ${r.realAfter.y})。`)] };
    }
    case 'status': {
      const r = await call('status');
      return {
        content: [
          text(
            `虚拟鼠标：浮层 ${r.overlay}，虚拟光标 (${r.x}, ${r.y})；真实指针 (${r.realX}, ${r.realY})；最近操作 ${r.lastAction}；进程 ${r.pid}，已运行 ${Math.round(r.uptimeMs / 1000)}s。`,
          ),
        ],
      };
    }
    default:
      throw new Error(`unknown tool: ${name}`);
  }
}

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function reply(id, result) {
  send({ jsonrpc: '2.0', id, result });
}

function replyError(id, code, message) {
  send({ jsonrpc: '2.0', id, error: { code, message } });
}

let pendingInput = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', async (chunk) => {
  pendingInput += chunk;
  let idx;
  while ((idx = pendingInput.indexOf('\n')) !== -1) {
    const line = pendingInput.slice(0, idx).trim();
    pendingInput = pendingInput.slice(idx + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }
    if (msg.method === undefined) continue;
    try {
      if (msg.method === 'initialize') {
        reply(msg.id, {
          protocolVersion: msg.params?.protocolVersion ?? '2025-06-18',
          capabilities: { tools: {} },
          serverInfo: { name: 'vmouse', version: '1.0.0' },
        });
      } else if (msg.method === 'notifications/initialized' || msg.method === 'initialized') {
        // notification, no reply
      } else if (msg.method === 'ping') {
        reply(msg.id, {});
      } else if (msg.method === 'tools/list') {
        reply(msg.id, { tools });
      } else if (msg.method === 'tools/call') {
        try {
          const result = await callTool(msg.params);
          reply(msg.id, result);
        } catch (e) {
          reply(msg.id, { content: [text(`操作失败：${e.message}`)], isError: true });
        }
      } else if (msg.id !== undefined) {
        replyError(msg.id, -32601, `method not found: ${msg.method}`);
      }
    } catch (e) {
      if (msg.id !== undefined) replyError(msg.id, -32000, e.message);
    }
  }
});

function shutdown() {
  if (helper) {
    try { helper.stdin.end(); } catch {}
    try { helper.kill(); } catch {}
    helper = null;
  }
  process.exit(0);
}

process.stdin.on('end', shutdown);
process.on('SIGTERM', shutdown);
process.on('exit', () => {
  if (helper) {
    try { helper.kill(); } catch {}
  }
});
