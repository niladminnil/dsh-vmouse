# 架构与实现

本文说明 dsh-vmouse 由哪些部件组成、请求怎么走、关键设计取舍。面向想改代码或做代码审查的读者。

## 组件与数据流

```text
┌──────────────────────────── DSH Desktop（Cordis Host）────────────────────────────┐
│                                                                                    │
│  cordis.patch.yml                                                                  │
│   ├─ [vmouse-mcp] @deepseek-ai/dsh-mcp-client                                     │
│   │     serverName: vmouse, transport: stdio, command: powershell.exe             │
│   │                                                                                │
│   └─ [vmouse-skill-filesystem] @deepseek-ai/dsh-skill-filesystem                  │
│         customSkillDirs: <profile>\node_modules\dsh-vmouse\skills                 │
│                                                                                    │
└───────────────────────────────┬────────────────────────────────────────────────────┘
                                │ stdio（启动时把 Node 进程接上，stdio 直通）
                                ▼
                    powershell.exe -NoProfile -NonInteractive -STA
                                  -ExecutionPolicy Bypass
                                  -File launch.ps1
                                │  找 node.exe（见「移植性设计」）
                                ▼
                        node.exe  server.mjs
                          │  MCP JSON-RPC over stdio（initialize / tools/list / tools/call）
                          │
                          │  stdin/stdout：每行一条 base64(JSON) 请求/响应
                          ▼
                    powershell.exe -STA vmouse.ps1（常驻）
                          │  Add-Type 内联 C#（VMouseHost）
                          ▼
                Win32：分层窗口浮层 + PostMessage 窗口消息注入
```

对应文件：

| 文件 | 职责 |
|---|---|
| `cordis.patch.yml` | 声明两个 Host 扩展：MCP server（`vmouse`）与 skill 目录提供者。不含任何机器绝对路径。 |
| `launch.ps1` | 找到可用的 Node.js，`& node server.mjs`。找不到时打印诊断并以非零码退出，让 DSH 明确报启动失败而不是挂起。 |
| `server.mjs` | MCP stdio server：实现 `initialize` / `tools/list` / `tools/call`，声明 5 个工具，把调用转给 `vmouse.ps1`，把结果整理成中文文本返回。 |
| `vmouse.ps1` | 常驻 PowerShell：创建浮层窗口、画光标/波纹、解析目标窗口、投递鼠标消息；`real: true` 时短暂借用真实指针。 |
| `skills/virtual-mouse/SKILL.md` | 教 agent 何时用、坐标怎么来、失败时的回退顺序。 |

## 请求时序

以一次 `mcp__vmouse__click` 为例：

```text
Agent
  │ tools/call { name: "click", arguments: {x, y} }
  ▼
DSH mcp-client ──stdio──► launch.ps1（powershell.exe，负责 exec node）
  │                          └── server.mjs 读取一行 JSON-RPC
  │                              ├── callTool("click")
  │                              ├── 生成 {id, cmd:"click", x, y, ...} → base64 → 一行写入 vmouse.ps1 stdin
  ▼                              │
vmouse.ps1（常驻 STA）◄──────────┘
  ├── ResolveTarget：WindowFromPoint / ChildWindowFromPointEx / ScreenToClient 解析目标窗口与客户区坐标
  ├── 画浮层：光标移到 (x,y) + 点击波纹
  ├── PostMouse：WM_MOUSEMOVE → WM_LBUTTONDOWN → WM_LBUTTONUP（双击用 WM_LBUTTONDBLCLK）
  ├── 读真实指针坐标（realBefore/realAfter，只读 GetCursorPos，不移动）
  └── 一行 JSON 响应 → server.mjs → MCP 结果文本 → Agent
```

要点：

- `server.mjs` 启动 `vmouse.ps1` 后**不会等待整个进程结束**，而是按 `id` 把一行响应匹配到对应请求；进程退出时把所有在途请求 reject，并把 stderr 尾部附到错误里。
- 工具调用超时：`cordis.patch.yml` 设 `toolCallTimeoutMs: 60000`；`server.mjs` 内部单次调用默认 30 秒，`drag` 45 秒。
- `failOnStartupError: true`：MCP server 起不来时 DSH 直接报错，避免工具静默不可用。

## 为什么用 MCP 而不是原生 Host 插件

- **只依赖稳定契约**：`cordis.patch.yml` 只用两个公开扩展点（`dsh-mcp-client`、`dsh-skill-filesystem`），插件与 DSH 内部 Host API / 服务注册表解耦。DSH 升级通常不需要改插件。
- **进程隔离**：耗时不定的 PowerShell 常驻进程（`Add-Type` 编译、窗口消息等待）在独立进程里，崩溃或卡住不会拖垮 DSH 主进程。
- **可独立测试**：`server.mjs` 是标准 MCP stdio server，可以不经过 DSH，用仓库自带的 `test/rpc.mjs` 直接做协议级冒烟。
- **代价**：多一层 stdio 转发；工具描述必须自包含（agent 只看得到工具名/描述/schema）。

## 为什么用 PowerShell 实现

- **系统自带**：Windows 10/11 自带 Windows PowerShell 5.1，用户不需要额外安装编译器或 Node 包；Node.js 用 DSH 自带的（`launch.ps1` 负责找），仓库里没有第三方 npm 依赖。
- **直接 P/Invoke**：`Add-Type` 内联 C#，可以声明 `user32.dll` / `gdi32.dll` 函数、定义 `BLENDFUNCTION` 等结构，实现分层窗口与消息注入；同时用 WinForms 消息泵和定时器驱动动画。
- **单进程常驻、开销低**：浮层与注入共用一个 STA 进程，避免每次操作冷启动。
- **审计友好**：`vmouse.ps1` 是单个明文文件，无压缩/混淆、无网络请求，方便代码审查。
- **代价**：首次使用要编译内联 C#（一次性延迟，几秒）；脚本依赖系统 PowerShell（不是 `pwsh`）——`cordis.patch.yml` 与 `server.mjs` 都显式用 `powershell.exe` 并带 `-ExecutionPolicy Bypass`，不依赖用户系统里的脚本执行策略设置。

常驻进程内的参数（`vmouse.ps1` 顶部）：

| 常量 | 值 | 含义 |
|---|---|---|
| `S` | 400 | 浮层画布尺寸（像素，正方形，逐帧整块更新） |
| `VISIBLE_MS` | 3200 | 操作后光标保持完全可见的时长 |
| `FADE_MS` | 420 | 之后淡出时长 |
| `RIPPLE_MS` | 760 | 点击波纹动画时长 |
| `FRAME_MS` | 30 | 动画帧间隔（约 33fps） |

## 关键 Win32 API

### 浮层窗口

| API / 样式 | 作用 |
|---|---|
| `WS_EX_LAYERED` | 分层窗口，支持逐像素 Alpha |
| `WS_EX_TRANSPARENT` | 鼠标完全穿透：点浮层等于点它下面那一层，不会挡住用户操作 |
| `WS_EX_NOACTIVATE` | 点击/显示不抢焦点 |
| `WS_EX_TOOLWINDOW` | 不进任务栏、不参与 Alt+Tab |
| `UpdateLayeredWindow` + `ULW_ALPHA` | 把一块 32 位 DIB 按 Alpha 合成到屏幕；配合 `BLENDFUNCTION{BlendOp=AC_SRC_OVER, AlphaFormat=AC_SRC_ALPHA}` 实现真正的逐像素透明（青色光标、波纹、淡出都靠它） |
| `SetProcessDpiAwarenessContext(-4)` / `SetProcessDPIAware()` | 进程 DPI aware，保证工具坐标 = 物理像素 = 截图坐标 |

每帧流程：在 `Bitmap` 上绘制 → `GetHbitmap` → `CreateCompatibleDC`/`SelectObject` → `UpdateLayeredWindow` → 释放 GDI 对象。窗口 `TopMost`，`ShowWithoutActivation`，不重写 `OnPaint`（内容完全由 `UpdateLayeredWindow` 提供）。

### 消息注入

| API | 作用 |
|---|---|
| `WindowFromPoint` / `GetAncestor(GA_ROOT)` | 从屏幕坐标解析目标顶层窗口（浮层是穿透的，不会命中自己） |
| `ChildWindowFromPointEx` | 逐层找到最深的子控件 |
| `ScreenToClient` | 屏幕坐标 → 目标客户区坐标（`lParam` 需要客户区坐标） |
| `PostMessage` | 投递 `WM_MOUSEMOVE` / `WM_LBUTTONDOWN` / `WM_LBUTTONUP` / `WM_LBUTTONDBLCLK` / `WM_RBUTTON*` / `WM_MBUTTON*` / `WM_MOUSEWHEEL`，用 `wParam` 带 `MK_*` 键状态，`lParam` 打包 `MAKELPARAM(x, y)` |
| `GetCursorPos` | 只读真实指针坐标，用于响应里的 `realBefore` / `realAfter` 自证「没有移动真实指针」 |
| `SetCursorPos` + `mouse_event` | **仅在 `real: true` 时使用**：记下原坐标 → 移过去 → 点击/分步拖动/滚动 → 移回原坐标 |

`hwnd` / `window` 参数允许跳过坐标命中解析，直接把消息投给指定窗口（可操作被遮挡的窗口）。

## 移植性设计

仓库里没有任何机器绝对路径，靠「profile 目录 + 包安装位置」拼接：

- `cordis.patch.yml` 用 Loader 的 `!!js` 表达式：

  ```yaml
  !!js 'decodeURIComponent(baseUrl).replace("file:///", "") + "node_modules/dsh-vmouse/launch.ps1"'
  ```

  `baseUrl` 是当前 profile 目录（`file:///` URL），`node_modules/dsh-vmouse` 是 pnpm 的安装位置。只要**包名与目录名一致**（`package.json` 的 `name` 是 `dsh-vmouse`），link / tarball / git / 本地路径各种安装方式都落到同一相对路径，无需改配置。
- skill 目录同理：`<profile>\node_modules\dsh-vmouse\skills`，交给 `dsh-skill-filesystem` 的 `customSkillDirs`。
- `launch.ps1` 的 Node 查找顺序（从高到低）：`DSH_VMOUSE_NODE` → `PATH` 上的 `node` → 父进程是 `node.exe` 时用父进程可执行文件 → 父进程安装目录下 DSH 自带的 `resources\runtime\<arch>\primary-runtime\dependencies\node\bin\node.exe`（以及 `resources\node\node.exe` 等兼容位置）→ 系统安装的 Node.js（`%ProgramFiles%\nodejs`、`%LOCALAPPDATA%\Programs\nodejs`）。全部失败才报错退出。
- `vmouse.ps1` 与 `server.mjs` 用各自所在目录（`$PSScriptRoot` / `import.meta.url`）定位彼此，因此整包可以放在任意路径，包括带空格和中文的路径。

## 安全模型

- **进程边界**：DSH → `powershell.exe`（launch）→ `node.exe`（MCP server）→ `powershell.exe`（常驻 vmouse）。四层进程，任何一层异常都不会让 DSH 主进程崩溃。
- **不联网**：没有 HTTP/WebSocket 客户端，没有遥测；pnpm 只在**安装阶段**访问 GitHub 下载 tarball。
- **无第三方依赖**：`package.json` 没有 `dependencies`；`server.mjs` 只用 Node 内置模块。
- **权限**：不请求管理员；受 Windows UIPI 限制，无法向管理员权限窗口注入消息。
- **数据**：不收集、不上传用户数据；仓库自带的验证脚本只写 `test\` 下的本地日志文件（已被 `.gitignore` 忽略）。
- **能力边界**：插件能在屏幕上画一层透明浮层、向窗口投递鼠标消息，等价于「本机 UI 自动化」，因此建议安装前审阅 `vmouse.ps1` / `server.mjs`，并只从可信来源安装。
