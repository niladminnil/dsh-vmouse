#!/usr/bin/env node
/**
 * vmouse MCP stdio 冒烟脚本（零第三方依赖，纯 ESM）
 *
 * 用法：
 *   node rpc.mjs --x 480 --y 300 [--button left] [--clicks 1] \
 *                [--server <仓库>\server.mjs] [--timeout 5000]
 *
 * 流程（与 MCP 规范顺序一致）：
 *   initialize(protocolVersion 2025-06-18) → notifications/initialized
 *   → tools/list（打印工具名清单）→ tools/call: status, move, click, status
 *   每一对「请求 → 响应」都完整打印，便于人工核对。
 *
 * 两种运行模式（自动选择，无需手工指定）：
 *   stream 模式：正常环境，spawn(process.execPath, [server])，逐条请求/响应。
 *   batch  模式：本机 DSH 沙箱禁止 Node 用管道 stdio 启动子进程（实测 spawn EPERM），
 *               此时自动改用「文件描述符 stdio」把请求一次性喂给 server，再轮询读取响应。
 *               功能等价（initialize/initialized/tools/list/tools/call 都会真实执行），
 *               区别只是请求会一次性发送、响应以轮询方式收集；超时仍是全局 5s。
 *
 * 退出码：
 *   0 = 全部成功
 *   1 = 协议错误 / tools/call 返回 isError / spawn 失败 / server 提前退出
 *   2 = 全局超时（默认 5s，可用 --timeout 覆盖）
 *
 * server 不存在、未实现或完全不响应时都会在超时内优雅退出，不会挂死。
 */

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const DEFAULT_SERVER = fileURLToPath(new URL('../server.mjs', import.meta.url));
const DEFAULT_TIMEOUT_MS = 5000;
const PROTOCOL_VERSION = '2025-06-18';
const CLIENT_INFO = { name: 'vmouse-rpc-smoke', version: '1.0.0' };

const ctx = {
  opts: null,
  serverPath: '',
  child: null,
  failures: [],
  done: false,
  mode: 'unknown',
  deadline: 0,
  tmpDir: null,
  nextId: 1,
  batchSeq: 0,
  streamPending: new Map(),
  streamTimer: null,
};

function print(line = '') {
  process.stdout.write(String(line) + '\n');
}

function fail(message) {
  ctx.failures.push(message);
  print(`[FAIL] ${message}`);
}

function remainingMs() {
  return Math.max(250, ctx.deadline - Date.now());
}

function killChild() {
  const child = ctx.child;
  if (!child) return;
  ctx.child = null;
  try {
    if (child.exitCode === null && !child.killed) child.kill();
  } catch { /* ignore */ }
  try {
    if (child.pid) {
      spawn(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', 'taskkill', '/pid', String(child.pid), '/t', '/f'], {
        stdio: 'ignore',
        windowsHide: true,
      }).on('error', () => {});
    }
  } catch { /* ignore */ }
}

function cleanupTmp() {
  if (!ctx.tmpDir) return;
  try {
    fs.rmSync(ctx.tmpDir, { recursive: true, force: true });
  } catch { /* ignore */ }
  ctx.tmpDir = null;
}

function finish(code) {
  if (ctx.done) return;
  ctx.done = true;
  if (ctx.streamTimer) {
    clearTimeout(ctx.streamTimer);
    ctx.streamTimer = null;
  }
  killChild();
  cleanupTmp();
  print('');
  print(`[vmouse-rpc] 结束，退出码 ${code}`);
  process.exitCode = code;
  // 兜底：若还有句柄没释放，最多等 1.5s 强制退出。
  const force = setTimeout(() => process.exit(code), 1500);
  force.unref();
}

// ---------- 参数 ----------
function usage() {
  print(`用法: node rpc.mjs [选项]

选项:
  --x <int>         目标屏幕 X（默认 480）
  --y <int>         目标屏幕 Y（默认 300）
  --button <name>   left | right | middle（默认 left）
  --clicks <int>    点击次数（默认 1）
  --server <path>   MCP server 入口 .mjs（默认 ${DEFAULT_SERVER}；
                    也可用环境变量 VMOUSE_SERVER 覆盖）
  --timeout <ms>    全局超时，默认 ${DEFAULT_TIMEOUT_MS}
  -h, --help        显示本帮助

退出码: 0 成功 / 1 失败（协议错误、isError、server 退出）/ 2 超时`);
}

function parseInteger(value, flag) {
  const n = Number(value);
  if (!Number.isInteger(n)) throw new Error(`${flag} 需要整数，收到 "${value}"`);
  return n;
}

function parseArgs(argv) {
  const opts = {
    x: 480,
    y: 300,
    button: 'left',
    clicks: 1,
    server: process.env.VMOUSE_SERVER || DEFAULT_SERVER,
    timeout: DEFAULT_TIMEOUT_MS,
    help: false,
  };

  for (let i = 0; i < argv.length; i++) {
    let arg = argv[i];
    let inlineValue;
    if (arg.startsWith('--') && arg.includes('=')) {
      const eq = arg.indexOf('=');
      inlineValue = arg.slice(eq + 1);
      arg = arg.slice(0, eq);
    }
    const takeValue = () => {
      if (inlineValue !== undefined) return inlineValue;
      if (i + 1 >= argv.length) throw new Error(`${arg} 缺少参数值`);
      return argv[++i];
    };

    switch (arg) {
      case '--x': opts.x = parseInteger(takeValue(), '--x'); break;
      case '--y': opts.y = parseInteger(takeValue(), '--y'); break;
      case '--clicks': opts.clicks = parseInteger(takeValue(), '--clicks'); break;
      case '--timeout': opts.timeout = parseInteger(takeValue(), '--timeout'); break;
      case '--button': {
        const b = String(takeValue()).toLowerCase();
        if (!['left', 'right', 'middle'].includes(b)) {
          throw new Error(`--button 只能是 left|right|middle，收到 "${b}"`);
        }
        opts.button = b;
        break;
      }
      case '--server': opts.server = takeValue(); break;
      case '-h':
      case '--help': opts.help = true; break;
      default: throw new Error(`未知参数: ${arg}（用 --help 查看用法）`);
    }
  }

  if (opts.clicks < 1) throw new Error('--clicks 必须 >= 1');
  if (opts.timeout < 1) throw new Error('--timeout 必须 >= 1');
  return opts;
}

// ---------- 响应判定共用 ----------
function resultText(resp) {
  const content = resp && resp.result && resp.result.content;
  if (!Array.isArray(content)) return '';
  const joined = content
    .filter((item) => item && typeof item.text === 'string')
    .map((item) => item.text)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();
  return joined.length > 500 ? joined.slice(0, 500) + '…' : joined;
}

function checkRpcResponse(label, resp) {
  if (!resp) {
    fail(`${label} 没有响应`);
    return false;
  }
  if (resp.error) {
    fail(`${label} 协议错误: ${JSON.stringify(resp.error)}`);
    return false;
  }
  if (resp.result === undefined) {
    fail(`${label} 响应缺少 result 字段: ${JSON.stringify(resp)}`);
    return false;
  }
  return true;
}

function reportToolResult(label, resp) {
  if (!checkRpcResponse(label, resp)) return;
  const result = resp.result || {};
  if (result.isError) {
    const text = resultText(resp);
    fail(`${label} 返回 isError${text ? ': ' + text : ''}`);
    return;
  }
  const text = resultText(resp);
  print(`[ok] ${label}${text ? ': ' + text : ''}`);
}

function resolveToolName(tools, canonical) {
  const names = (Array.isArray(tools) ? tools : [])
    .map((t) => (t && typeof t.name === 'string' ? t.name : ''))
    .filter(Boolean);
  if (names.includes(canonical)) return { name: canonical, found: true };
  const lower = (s) => s.toLowerCase();
  const bySuffix = names.find((n) => lower(n).endsWith(canonical));
  if (bySuffix) return { name: bySuffix, found: true };
  const byContains = names.find((n) => lower(n).includes(canonical));
  if (byContains) return { name: byContains, found: true };
  return { name: canonical, found: false };
}

function initializeParams() {
  return {
    protocolVersion: PROTOCOL_VERSION,
    capabilities: {},
    clientInfo: CLIENT_INFO,
  };
}

// ---------- stream 模式（正常环境：管道 stdio，逐条交互） ----------
function runStreamMode() {
  ctx.mode = 'stream';
  let child;
  try {
    child = spawn(process.execPath, [ctx.serverPath], {
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
      cwd: path.dirname(ctx.serverPath),
    });
  } catch (err) {
    if (err && (err.code === 'EPERM' || err.code === 'EACCES')) {
      print(`[warn] 当前环境禁止 Node 用管道 stdio 启动子进程（${err.code}），自动切换为文件重定向批处理模式。`);
      return false;
    }
    fail(`spawn 失败: ${err && err.code ? err.code + ' ' : ''}${err && err.message}`);
    finish(1);
    return true;
  }
  ctx.child = child;

  const sendRaw = (msg) => {
    const line = JSON.stringify(msg);
    print(`--> ${line}`);
    try {
      child.stdin.write(line + '\n');
    } catch (err) {
      fail(`写入 server stdin 失败: ${err.message}`);
      finish(1);
    }
  };

  const request = (method, params) => {
    if (ctx.done) return Promise.reject(new Error('脚本已结束'));
    const id = ctx.nextId++;
    const msg = { jsonrpc: '2.0', id, method };
    if (params !== undefined) msg.params = params;
    return new Promise((resolve, reject) => {
      ctx.streamPending.set(id, { method, resolve, reject });
      sendRaw(msg);
    });
  };

  const notify = (method) => {
    if (ctx.done) return;
    sendRaw({ jsonrpc: '2.0', method });
  };

  const handleLine = (line) => {
    const text = line.trim();
    if (!text) return;
    let msg;
    try {
      msg = JSON.parse(text);
    } catch {
      print(`[server stdout] ${text}`);
      return;
    }
    if (msg && msg.id !== undefined && msg.id !== null && ctx.streamPending.has(msg.id)) {
      const pending = ctx.streamPending.get(msg.id);
      ctx.streamPending.delete(msg.id);
      print(`<-- ${JSON.stringify(msg)}`);
      pending.resolve(msg);
      return;
    }
    if (msg && msg.method) {
      print(`<-- (notification) ${JSON.stringify(msg)}`);
      return;
    }
    print(`<-- (未匹配响应) ${JSON.stringify(msg)}`);
  };

  child.on('error', (err) => {
    fail(`spawn/子进程错误: ${err.code || ''} ${err.message}`);
    finish(1);
  });
  child.on('exit', (code, signal) => {
    const detail = `code=${code} signal=${signal === null ? 'null' : signal}`;
    print(`[info] server 进程退出（${detail}）`);
    for (const [, pending] of ctx.streamPending) {
      pending.reject(new Error(`server 提前退出（${detail}）`));
    }
    ctx.streamPending.clear();
    if (ctx.done) return;
    fail(`server 在测试完成前退出（${detail}）`);
    finish(1);
  });
  child.stdin.on('error', (err) => {
    print(`[warn] server stdin 错误: ${err.message}`);
  });

  readline.createInterface({ input: child.stdout, crlfDelay: Infinity }).on('line', handleLine);
  readline.createInterface({ input: child.stderr, crlfDelay: Infinity }).on('line', (line) => {
    if (line.trim()) print(`[server stderr] ${line}`);
  });

  ctx.streamTimer = setTimeout(() => {
    const waiting = [...ctx.streamPending.values()].map((p) => p.method);
    print('');
    print(`[FAIL] 超时 ${ctx.opts.timeout}ms，未收到响应的请求: ${waiting.length ? waiting.join(', ') : '(无)'}`);
    print('[hint] server 可能未实现、路径不对，或没有按 MCP stdio 协议回应。');
    finish(2);
  }, remainingMs());
  ctx.streamTimer.unref();

  (async () => {
    print('[step 1] initialize');
    const initResp = await request('initialize', initializeParams());
    if (!checkRpcResponse('initialize', initResp)) {
      finish(1);
      return;
    }
    const serverInfo = initResp.result && initResp.result.serverInfo;
    if (serverInfo) print(`[info] serverInfo: ${JSON.stringify(serverInfo)}`);

    notify('notifications/initialized');

    print('');
    print('[step 2] tools/list');
    const listResp = await request('tools/list', {});
    if (!checkRpcResponse('tools/list', listResp)) {
      finish(1);
      return;
    }
    const tools = Array.isArray(listResp.result.tools) ? listResp.result.tools : [];
    if (!tools.length) fail('tools/list 没有返回任何工具');
    print(`[info] 工具 ${tools.length} 个: ${tools.map((t) => (t && t.name) || '?').join(', ')}`);

    const statusTool = resolveToolName(tools, 'status');
    const moveTool = resolveToolName(tools, 'move');
    const clickTool = resolveToolName(tools, 'click');
    print(`[info] 工具映射: status=${statusTool.name} move=${moveTool.name} click=${clickTool.name}`);
    for (const item of [['status', statusTool], ['move', moveTool], ['click', clickTool]]) {
      if (!item[1].found) print(`[warn] tools/list 中没找到 ${item[0]} 类工具，仍尝试调用 "${item[1].name}"`);
    }

    print('');
    print('[step 3] tools/call status');
    reportToolResult('status', await request('tools/call', { name: statusTool.name, arguments: {} }));

    print('');
    print('[step 4] tools/call move');
    reportToolResult('move', await request('tools/call', {
      name: moveTool.name,
      arguments: { x: ctx.opts.x, y: ctx.opts.y },
    }));

    print('');
    print('[step 5] tools/call click');
    reportToolResult('click', await request('tools/call', {
      name: clickTool.name,
      arguments: { x: ctx.opts.x, y: ctx.opts.y, button: ctx.opts.button, clicks: ctx.opts.clicks },
    }));

    print('');
    print('[step 6] tools/call status');
    reportToolResult('status', await request('tools/call', { name: statusTool.name, arguments: {} }));

    print('');
    if (ctx.failures.length) {
      print(`[总结] 失败 ${ctx.failures.length} 项:`);
      for (const f of ctx.failures) print(`  - ${f}`);
      finish(1);
    } else {
      print('[总结] 全部步骤成功');
      finish(0);
    }
  })().catch((err) => {
    if (ctx.done) return;
    fail(`脚本异常: ${err && err.stack ? err.stack : err}`);
    finish(1);
  });

  return true;
}

// ---------- batch 模式（沙箱内管道不可用：文件 fd stdio，一次性请求 + 轮询响应） ----------
function ensureTmpDir() {
  if (ctx.tmpDir) return ctx.tmpDir;
  let base = os.tmpdir();
  try {
    const scriptDir = path.dirname(fileURLToPath(import.meta.url));
    fs.accessSync(scriptDir, fs.constants.W_OK);
    base = scriptDir;
  } catch { /* 用系统临时目录 */ }
  ctx.tmpDir = fs.mkdtempSync(path.join(base, '.rpc-tmp-'));
  return ctx.tmpDir;
}

/**
 * 一个批处理回合：把 messages 一次性写入 stdin 文件，spawn server（stdio 指向文件 fd），
 * 轮询读取 stdout 文件，直到 expectedIds 全部有响应 / 子进程退出 / 超时。
 */
function batchExchange(messages, expectedIds, label) {
  return new Promise((resolve) => {
    const dir = ensureTmpDir();
    const seq = (ctx.batchSeq += 1);
    const reqFile = path.join(dir, `req-${seq}.jsonl`);
    const resFile = path.join(dir, `res-${seq}.jsonl`);
    const errFile = path.join(dir, `err-${seq}.txt`);

    const lines = messages.map((m) => JSON.stringify(m));
    fs.writeFileSync(reqFile, lines.join('\n') + '\n', 'utf8');
    print(`\n[batch ${label}] 一次性写入 ${lines.length} 条请求：`);
    for (const line of lines) print(`--> ${line}`);

    const responses = new Map();
    let processedLines = 0;
    let stderrConsumed = 0;
    let childExited = false;
    let settled = false;
    let poll = null;
    let timer = null;
    let child = null;
    let rfd = null;
    let wfd = null;
    let efd = null;

    const settle = (result) => {
      if (settled) return;
      settled = true;
      if (poll) clearInterval(poll);
      if (timer) clearTimeout(timer);
      poll = null;
      timer = null;
      if (!childExited && child) {
        try {
          if (child.exitCode === null && !child.killed) child.kill();
        } catch { /* ignore */ }
        try {
          spawn(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', 'taskkill', '/pid', String(child.pid), '/t', '/f'], {
            stdio: 'ignore',
            windowsHide: true,
          }).on('error', () => {});
        } catch { /* ignore */ }
      }
      setTimeout(() => {
        if (rfd !== null) { try { fs.closeSync(rfd); } catch { /* ignore */ } }
        if (wfd !== null) { try { fs.closeSync(wfd); } catch { /* ignore */ } }
        if (efd !== null) { try { fs.closeSync(efd); } catch { /* ignore */ } }
        resolve(result);
      }, childExited ? 0 : 150);
    };

    const readResponses = () => {
      let raw;
      try {
        raw = fs.readFileSync(resFile, 'utf8');
      } catch {
        return;
      }
      const parts = raw.split('\n');
      // 最后一段可能是写了一半的行，直接丢弃（下一轮再取）
      const complete = parts.slice(0, -1);
      for (let i = processedLines; i < complete.length; i++) {
        processedLines = i + 1;
        const text = complete[i].trim();
        if (!text) continue;
        let msg;
        try {
          msg = JSON.parse(text);
        } catch {
          print(`[server stdout] ${text}`);
          continue;
        }
        if (msg && msg.id !== undefined && msg.id !== null) {
          responses.set(msg.id, msg);
          print(`<-- ${JSON.stringify(msg)}`);
        } else if (msg && msg.method) {
          print(`<-- (notification) ${JSON.stringify(msg)}`);
        } else {
          print(`<-- (未匹配响应) ${JSON.stringify(msg)}`);
        }
      }
    };

    const readStderr = () => {
      let raw;
      try {
        raw = fs.readFileSync(errFile, 'utf8');
      } catch {
        return;
      }
      const chunk = raw.slice(stderrConsumed);
      const nl = chunk.lastIndexOf('\n');
      if (nl < 0) return;
      for (const line of chunk.slice(0, nl).split('\n')) {
        if (line.trim()) print(`[server stderr] ${line}`);
      }
      stderrConsumed += nl + 1;
    };

    const allDone = () => expectedIds.every((id) => responses.has(id));

    try {
      rfd = fs.openSync(reqFile, 'r');
      wfd = fs.openSync(resFile, 'w');
      efd = fs.openSync(errFile, 'w');
      child = spawn(process.execPath, [ctx.serverPath], {
        stdio: [rfd, wfd, efd],
        windowsHide: true,
        cwd: path.dirname(ctx.serverPath),
      });
      ctx.child = child;
    } catch (err) {
      fail(`batch spawn 失败: ${err.code || ''} ${err.message}`);
      settle({ ok: false, timedOut: false, responses, error: String(err && err.message) });
      return;
    }

    child.on('error', (err) => {
      fail(`batch 子进程错误: ${err.code || ''} ${err.message}`);
      settle({ ok: false, timedOut: false, responses, error: String(err && err.message) });
    });
    child.on('exit', () => {
      childExited = true;
      ctx.child = null;
      readResponses();
      readStderr();
      if (allDone()) {
        settle({ ok: true, timedOut: false, responses });
      } else {
        settle({ ok: false, timedOut: false, responses, error: 'server 在响应齐全前退出' });
      }
    });

    poll = setInterval(() => {
      readResponses();
      readStderr();
      if (allDone()) settle({ ok: true, timedOut: false, responses });
    }, 60);

    timer = setTimeout(() => {
      readResponses();
      readStderr();
      const missing = expectedIds.filter((id) => !responses.has(id));
      if (!missing.length) {
        settle({ ok: true, timedOut: false, responses });
      } else {
        settle({ ok: false, timedOut: true, responses, error: `超时，缺少响应 id: ${missing.join(',')}` });
      }
    }, remainingMs());
  });
}

function runBatchMode() {
  ctx.mode = 'batch';
  print('[mode] batch（文件描述符 stdio；当前环境不允许管道 stdio）');

  return (async () => {
    // phase 1: initialize + tools/list
    const initId = ctx.nextId++;
    const listId = ctx.nextId++;
    const phase1 = [
      { jsonrpc: '2.0', id: initId, method: 'initialize', params: initializeParams() },
      { jsonrpc: '2.0', method: 'notifications/initialized' },
      { jsonrpc: '2.0', id: listId, method: 'tools/list' },
    ];
    const r1 = await batchExchange(phase1, [initId, listId], 'phase1 initialize + tools/list');
    if (r1.timedOut) {
      print('');
      print(`[FAIL] 超时 ${ctx.opts.timeout}ms：server 没有完成 initialize/tools/list（${r1.error}）`);
      print('[hint] server 可能未实现、路径不对，或没有按 MCP stdio 协议回应。');
      finish(2);
      return;
    }
    if (!r1.ok && !r1.responses.has(initId) && !r1.responses.has(listId)) {
      fail(`server 未返回 initialize/tools/list（${r1.error}）`);
      finish(1);
      return;
    }

    const initResp = r1.responses.get(initId);
    if (!checkRpcResponse('initialize', initResp)) {
      finish(1);
      return;
    }
    const serverInfo = initResp.result && initResp.result.serverInfo;
    if (serverInfo) print(`[info] serverInfo: ${JSON.stringify(serverInfo)}`);

    const listResp = r1.responses.get(listId);
    if (!checkRpcResponse('tools/list', listResp)) {
      finish(1);
      return;
    }
    const tools = Array.isArray(listResp.result.tools) ? listResp.result.tools : [];
    if (!tools.length) fail('tools/list 没有返回任何工具');
    print(`[info] 工具 ${tools.length} 个: ${tools.map((t) => (t && t.name) || '?').join(', ')}`);

    const statusTool = resolveToolName(tools, 'status');
    const moveTool = resolveToolName(tools, 'move');
    const clickTool = resolveToolName(tools, 'click');
    print(`[info] 工具映射: status=${statusTool.name} move=${moveTool.name} click=${clickTool.name}`);
    for (const item of [['status', statusTool], ['move', moveTool], ['click', clickTool]]) {
      if (!item[1].found) print(`[warn] tools/list 中没找到 ${item[0]} 类工具，仍尝试调用 "${item[1].name}"`);
    }

    // phase 2: 新会话里执行 status / move / click / status
    const ids = [];
    const calls = [
      ['status', { name: statusTool.name, arguments: {} }],
      ['move', { name: moveTool.name, arguments: { x: ctx.opts.x, y: ctx.opts.y } }],
      ['click', { name: clickTool.name, arguments: { x: ctx.opts.x, y: ctx.opts.y, button: ctx.opts.button, clicks: ctx.opts.clicks } }],
      ['status', { name: statusTool.name, arguments: {} }],
    ];
    const phase2 = [
      { jsonrpc: '2.0', id: ctx.nextId++, method: 'initialize', params: initializeParams() },
      { jsonrpc: '2.0', method: 'notifications/initialized' },
    ];
    ids.push(phase2[0].id);
    for (const [, params] of calls) {
      const id = ctx.nextId++;
      ids.push(id);
      phase2.push({ jsonrpc: '2.0', id, method: 'tools/call', params });
    }

    const r2 = await batchExchange(phase2, ids, 'phase2 tools/call(status/move/click/status)');
    if (r2.timedOut) {
      print('');
      print(`[FAIL] 超时 ${ctx.opts.timeout}ms：${r2.error}`);
      print('[hint] server 没有按 MCP stdio 协议回应 tools/call。');
      finish(2);
      return;
    }

    const labels = ['status', 'move', 'click', 'status'];
    for (let i = 0; i < calls.length; i++) {
      print('');
      print(`[step] tools/call ${labels[i]}`);
      const resp = r2.responses.get(ids[i + 1]);
      if (!resp) {
        fail(`${labels[i]} 缺少响应（${r2.error || 'server 提前退出'}）`);
        continue;
      }
      reportToolResult(labels[i], resp);
    }

    print('');
    if (ctx.failures.length) {
      print(`[总结] 失败 ${ctx.failures.length} 项:`);
      for (const f of ctx.failures) print(`  - ${f}`);
      finish(1);
    } else {
      print('[总结] 全部步骤成功');
      finish(0);
    }
  })();
}

// ---------- 入口 ----------
async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    usage();
    return;
  }
  ctx.opts = opts;
  ctx.serverPath = path.resolve(opts.server);
  ctx.deadline = Date.now() + opts.timeout;

  print(`[vmouse-rpc] node      = ${process.execPath}`);
  print(`[vmouse-rpc] server    = ${ctx.serverPath}`);
  print(`[vmouse-rpc] target    = (${opts.x},${opts.y}) button=${opts.button} clicks=${opts.clicks}`);
  print(`[vmouse-rpc] timeout   = ${opts.timeout}ms`);
  if (!fs.existsSync(ctx.serverPath)) {
    print(`[warn] server 文件不存在: ${ctx.serverPath}（继续尝试启动，失败会以退出码 1 结束）`);
  }
  print('');

  const streamHandled = runStreamMode();
  if (!streamHandled) {
    await runBatchMode();
  }
}

main().catch((err) => {
  if (ctx.done) return;
  fail(`脚本异常: ${err && err.stack ? err.stack : err}`);
  finish(1);
});
