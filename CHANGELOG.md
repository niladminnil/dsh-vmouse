# Changelog

本项目的所有重要变更都记录在这里。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.0] - 2026-11-18

首个公开发布版本。

### Added

- **虚拟光标浮层**：置顶分层窗口绘制青色箭头光标（带 AI 徽标）与点击波纹；鼠标完全穿透、不抢焦点、不进任务栏，操作后约 3.2 秒淡出。使用 `WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW` + `UpdateLayeredWindow` + `AC_SRC_ALPHA` 逐像素 Alpha。
- **窗口消息注入**：`click` / `drag` / `scroll` 通过 `PostMessage` 投递 `WM_MOUSEMOVE`、`WM_LBUTTONDOWN`、`WM_LBUTTONUP`、`WM_MOUSEWHEEL` 等窗口消息完成，默认不移动、不占用用户真实鼠标指针；支持先解析目标窗口与客户区坐标，也支持用 `hwnd` / `window` 直接投递给指定窗口（可点被遮挡的窗口）。
- **真实指针兜底**：所有工具支持 `real: true`，短暂借用真实指针完成操作后复原（`SetCursorPos` + `mouse_event`），用于游戏、Raw Input、DirectX·Vulkan 画布等不响应窗口消息的目标。
- **自证不抢鼠标**：`click` 的响应返回操作前后的真实指针坐标（`realBefore` / `realAfter`），`move` / `scroll` 的响应也返回真实指针坐标。
- **`status` 工具**：查询浮层可见性、虚拟光标坐标、真实指针坐标、最近操作、进程 PID 与运行时长。
- **`virtual-mouse` skill**：指导 agent 何时使用虚拟鼠标、如何从截图取坐标、标准操作流程与失败回退顺序（`hwnd`/`window` → `real: true` → 真实鼠标工具）。
- **可移植安装**：`cordis.patch.yml` 不写死机器路径，通过 `baseUrl` + `node_modules/dsh-vmouse` 相对路径解析；`launch.ps1` 自动查找 Node.js（`DSH_VMOUSE_NODE` → `PATH` → DSH 宿主 / 内置运行时 → 系统 Node.js），link / tarball / 本地路径等安装方式通用。
- **三种安装方式**：MCP `install_bundle` 一句话安装（pnpm 直接拉 GitHub tarball，无需 git）、命令行 `install.cmd` / `dsh plugin --profile desktop add "link:..."`、离线 zip 解压后本地安装。附带 `install.cmd` 与 `uninstall.cmd` 一键脚本（检查 DSH 是否已退出、`dsh` 命令是否可用，支持 `--dry-run` 预览，可用 `DSH_PROFILE` 指定 profile）。
- **发布工具**：`scripts/pack.ps1` 生成 npm 风格 tarball 并做自检；`.github/workflows/release.yml` 在推送 `v*` tag 时自动打包并发布 GitHub Release。
- **界面文案与图标**：`locale/zh.json`、`locale/en.json` 提供插件标题与描述；`icon.svg` 提供插件图标。
- **测试与验证**：`test/testtarget.ps1` WinForms 点击靶场（固定窗口、输出 `target.json` 与 `clicks.log`）；`test/rpc.mjs` MCP stdio 冒烟脚本（`initialize → tools/list → status → move → click → status`，自动适配沙箱环境）。
- **文档**：README（中文 + English summary）、安装与排障（`docs/INSTALL.md`）、架构说明（`docs/ARCHITECTURE.md`），以及 `docs/images/` 下的示意截图。

### Security

- 纯本地运行：不联网、无遥测、无第三方 npm 依赖，不请求管理员权限。
- 仅向窗口投递鼠标消息并绘制屏幕浮层；受 Windows UIPI 限制，不能操作管理员权限窗口。
- 仓库内脚本均为明文，方便安装前审查；测试日志只写 `test\` 下的本地文件。

[1.0.0]: https://github.com/niladminnil/dsh-vmouse/releases/tag/v1.0.0
