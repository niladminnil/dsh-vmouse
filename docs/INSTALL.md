# 安装与排障

本文档对应 **dsh-vmouse v1.0.0**，适用于 Windows 10 / 11 上的 DSH Desktop。

## 系统要求

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 10 / 11 |
| DSH | DSH Desktop，能正常启动（版本支持 bundle 插件与 `plugin_manager`） |
| PowerShell | 系统自带的 **Windows PowerShell 5.1**（`C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`），无需安装或配置 |
| Node.js | DSH Desktop 自带；`launch.ps1` 会自动查找，找不到时用环境变量 `DSH_VMOUSE_NODE` 指定 |
| 权限 | 不需要管理员权限；安装和使用都不写注册表、不装服务 |
| 其他 | 不需要安装 git（方式 A 由 pnpm 直接拉 GitHub tarball） |

## 安装前须知

- **方式 A** 可以在 DSH 运行时直接安装，装完可能需要重启一次 DSH Desktop。
- **方式 B（命令行）** 必须先**完全退出** DSH Desktop，否则 profile 文件被占用、插件行可能不生效。
- **方式 C** 适合离线 / 内网 / GitHub 访问不畅时使用。
- 插件会向窗口注入鼠标消息并绘制屏幕浮层，安装前建议先看 [README 的「安全提示」](../README.md#安全提示)。

---

## 方式 A【推荐 · 不用装任何东西】一句话交给 agent

1. 打开 DSH 里任意一个对话（哪个 agent 都行）。
2. 把下面这句话原样发出去，**把 `niladminnil` 换成你的 GitHub 用户名**：

   ```text
   帮我安装虚拟鼠标插件：用 plugin_manager 的 install_bundle，target 传 https://github.com/niladminnil/dsh-vmouse/archive/refs/tags/v1.0.0.tar.gz
   ```

3. agent 会调用 `plugin_manager` 的 `install_bundle`，由 pnpm 从 GitHub 下载 `v1.0.0` 的 tarball 安装到当前 profile 的 `node_modules\dsh-vmouse`，并把依赖写进 profile 的 `package.json`。这一步会执行 pnpm，属于正常安装行为。
4. 装好后让 agent 调一次 `mcp__vmouse__status` 验证；如果这时还看不到 `mcp__vmouse__*` 工具，**重新打开一次 DSH Desktop**，再让 agent 试。
5. 如果要装未来版本，把 URL 里的 `v1.0.0` 换成新的 tag 即可（详见「升级」）。

> 提示：GitHub 打不开或公司网络限制时，改用方式 C 下载 zip 后本地安装。

---

## 方式 B【命令行】完全退出 DSH 后，在仓库目录安装

1. **完全退出 DSH Desktop**：
   - 任务栏托盘图标右键 → 退出；
   - 再在任务管理器确认没有 DSH Desktop 的进程残留（否则文件被占用，安装结果可能不生效）。
2. 准备好仓库目录（GitHub 下载 zip 解压，或 `git clone`），放在一个**固定位置**，例如：

   ```text
   D:\配置\dsh-vmouse
   ```

   > `link:` 方式安装的是「指向该目录的链接」，之后不要移动或删除这个目录；移动后需要按本方式重新安装一次。
3. 在仓库目录任选其一：
   - 双击运行仓库根目录的 `install.cmd`（一键安装脚本）：它会先确认 DSH Desktop 已退出、`dsh` 命令可用，然后执行 `link:` 安装；`install.cmd --dry-run` 只打印将执行的命令、不做修改。安装目标 profile 默认 `desktop`，可用环境变量 `DSH_PROFILE` 指定其它 profile；
   - 或在命令行里手动执行：

     ```bat
     dsh plugin --profile desktop add "link:D:\配置\dsh-vmouse"
     ```

     把 `D:\配置\dsh-vmouse` 换成你的仓库绝对路径，`desktop` 换成你要安装到的 profile 名。
4. 重新打开 DSH Desktop。
5. 按「确认安装成功」一节验证。

> 如果终端提示找不到 `dsh` 命令，说明当前环境没有可用的 DSH 命令行，请改用方式 A 或方式 C。

---

## 方式 C【手动/离线】下载 zip 解压后让 agent 安装

1. 在 GitHub 仓库页面点 **Code → Download ZIP**（Release 页面的源码 zip 也可以），得到 `dsh-vmouse-1.0.0.zip`。
2. 解压到一个**固定的绝对路径**，例如：

   ```text
   D:\插件\dsh-vmouse
   ```

   确认该目录下直接能看到 `package.json`、`cordis.patch.yml`（不是外面又多套了一层文件夹）。
3. 让 agent 执行（target 传**解压后**的目录绝对路径）：

   ```yaml
   action: install_bundle
   target: D:\插件\dsh-vmouse
   ```

4. 让 agent 调 `mcp__vmouse__status` 验证；看不到工具就重启一次 DSH Desktop。

---

## 三种方式对比

| | A 一句话安装 | B 命令行 link | C 离线本地安装 |
|---|---|---|---|
| 需要 git | 不需要（pnpm 拉 tarball） | 不需要 | 不需要 |
| 需要退出 DSH | 不需要（装完可能需重启） | **需要完全退出** | 不需要（装完可能需重启） |
| 需要下载 zip | 不需要 | 需要（或 clone） | 需要 |
| 适合谁 | 所有人，尤其是第一次装 | 开发者、想改代码后立即生效 | 离线 / 内网 / GitHub 访问不畅 |
| 升级方式 | 重发 install_bundle，换成新 tag | `git pull` 后重启 DSH | 替换解压目录后重启或重装 |

---

## 确认安装成功

按顺序检查，全部通过即为装好：

1. **设置 → 插件**：列表里出现标题为 **「虚拟鼠标（agent 自己的光标）」** 的一行，描述为「给 agent 一只自己的鼠标：屏幕上有独立的青色光标……」（中文界面）。英文界面显示 "Virtual Mouse (the agent's own cursor)"。
2. **agent 工具**：让 agent 调用 `mcp__vmouse__status`，能返回「虚拟鼠标：浮层 …，虚拟光标 (x, y)；真实指针 (x, y)；最近操作 …」这类内容。
3. **skill**：agent 的技能列表里出现 `virtual-mouse`（描述为用虚拟鼠标做桌面点击/拖动/滚动）。
4. **肉眼验证**（可选）：让 agent 执行 `mcp__vmouse__move` 到屏幕上一个坐标，应能看到青色箭头光标出现约 3 秒后淡出，而真实鼠标指针不动。

> 如果第 1 项通过但第 2 项失败，看下面的「排障 → MCP 启动失败」。

---

## 排障

### MCP 启动失败 / `mcp__vmouse__*` 用不了

**症状**：插件行出现在设置里，但 agent 看不到工具，或调用时报错；设置 → 插件里 vmouse 的 MCP server 启动失败。

`cordis.patch.yml` 用系统 PowerShell 启动 `launch.ps1`，再由它找 `node.exe` 运行 `server.mjs`。找不到 Node 时 `launch.ps1` 会明确报错 `vmouse: cannot locate node.exe`。

`launch.ps1` 查找 `node.exe` 的顺序：

1. 环境变量 `DSH_VMOUSE_NODE`（显式指定，优先级最高）；
2. `PATH` 里的 `node`；
3. DSH 宿主进程自身的可执行文件（当宿主就是 `node.exe` 时）；
4. DSH Desktop 自带的 Node：`<DSH 安装目录>\resources\runtime\<arch>\primary-runtime\dependencies\node\bin\node.exe`；
5. 系统安装的 Node.js（`%ProgramFiles%\nodejs\node.exe`、`%LOCALAPPDATA%\Programs\nodejs\node.exe`）。

**先手工验证链路**（在 DSH 之外运行时要显式指定 Node，因为此时父进程不是 DSH 宿主）：

```powershell
# 用 DSH 自带的 Node 手工测试 launch.ps1 的 MCP 握手
$env:DSH_VMOUSE_NODE = 'D:\DEEPSEEK H\DSH Desktop\resources\runtime\x64\primary-runtime\dependencies\node\bin\node.exe'
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' | powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'D:\配置\dsh-vmouse\launch.ps1'
```

期望输出一行 JSON：

```json
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"vmouse","version":"1.0.0"}}}
```

- 如果报 `cannot locate node.exe`：说明当前环境找不到 Node。把 `DSH_VMOUSE_NODE` 设为任意可用的 `node.exe` 绝对路径后**完全重启** DSH Desktop（新进程才会读到环境变量），例如用 `setx` 写入用户环境变量：

  ```powershell
  setx DSH_VMOUSE_NODE "D:\DEEPSEEK H\DSH Desktop\resources\runtime\x64\primary-runtime\dependencies\node\bin\node.exe"
  ```

  注意：路径要指向 DSH **当前**内置 Node 的实际位置（DSH 升级后路径可能变化）。
- 如果命令能握手成功，但 DSH 里仍然失败：看 DSH「设置 → 插件」里的 server 报错，以及 profile 下 `.plugin-manager\logs` 的日志；也确认 profile 的 `package.json` 里确实写入了 `dsh-vmouse` 依赖。
- **首次调用偏慢**属正常：常驻 PowerShell 要 `Add-Type` 编译内联 C#，第一次点击可能多等几秒；`toolCallTimeoutMs` 为 60 秒，超时再排查。

### 「设置 → 插件」里没有这一行

1. **方式 B**：确认安装时 DSH 真的完全退出；重新打开后再看。
2. 检查当前 profile 的 `package.json`：`bundles` / `dependencies` 字段里应包含 `dsh-vmouse`；`node_modules\dsh-vmouse` 目录应存在。
3. 看 profile 下 `.plugin-manager\logs` 里的安装日志（pnpm 报错通常在这里）。
4. **方式 C**：确认 `install_bundle` 的 target 是**含 `package.json` 的那一层**绝对路径，不是 zip 文件路径，也不是它的上级目录。
5. 确认没有装到别的 profile（同一台机器可能有多个 profile）。

### 被安全软件拦截

- DSH 启动 PowerShell 时**显式**带 `-ExecutionPolicy Bypass`，不需要用户自己改系统脚本执行策略。
- 插件不需要管理员权限、不写注册表、不安装服务、不联网；只用 `powershell.exe` 运行仓库里的明文 `.ps1`。
- 若杀毒软件仍然拦截：把仓库目录（如 `D:\配置\dsh-vmouse`）加入信任/排除列表，或允许 `powershell.exe` 运行该目录下的脚本。
- 公司电脑策略禁止运行任何 PowerShell 脚本时，插件无法工作，需联系管理员放行。

### 权限（UIPI）相关的失败

普通权限的进程不能向**以管理员身份运行**的窗口投递鼠标消息。要让虚拟鼠标操作某个程序，请让该程序用普通权限运行；或让 DSH Desktop 也以管理员身份运行（不推荐，会扩大权限面）。

### 日志在哪看

- **DSH「设置 → 插件」**：插件/MCP server 的状态与最近错误。
- **profile 目录下的 `.plugin-manager\logs`**：安装（pnpm）与插件管理日志。profile 目录位置可以在 DSH 的设置/关于里确认。
- **MCP server 的 stderr** 会进入 DSH 日志；`server.mjs` 也会把 `vmouse.ps1` 的最后一段 stderr 附到工具调用错误里，调用失败时先看错误文本。

### 能调用但点不中目标

按顺序检查：

1. `mcp__vmouse__status`：虚拟光标坐标是否就是目标坐标；不对就重新截图定位。
2. 目标是否属于游戏 / Raw Input / DirectX·Vulkan 画布类程序——这类只认物理输入，改用 `click` / `drag` 的 `real: true`。
3. 目标窗口是否以管理员权限运行——受 UIPI 限制，改用普通权限窗口。
4. 先用 `hwnd`（窗口句柄）或 `window`（标题包含的文字）把点击直接投递给目标窗口，再决定是否用 `real: true`。

---

## 升级

- 先看当前装了什么版本：让 agent 用 `plugin_manager list_bundles` 查看 `dsh-vmouse`。
- **方式 A**：重新发一句话，把 URL 里的 `v1.0.0` 换成新版本 tag，例如 `.../archive/refs/tags/v1.1.0.tar.gz`。
- **方式 B（link）**：在仓库目录 `git pull` 更新代码，然后重启 DSH Desktop 即可生效（link 安装直接引用目录）。
- **方式 C**：下载新 zip 覆盖解压目录后重新 `install_bundle`，或直接重启 DSH Desktop。

## 卸载

任选其一：

- 让 agent 执行 `plugin_manager` 的 `remove_bundle`，target 传 `dsh-vmouse`；
- 打开「设置 → 插件」，找到「虚拟鼠标（agent 自己的光标）」停用或移除；
- 命令行方式安装的，**完全退出 DSH Desktop** 后在仓库目录运行 `uninstall.cmd`（等价于 `dsh plugin --profile desktop remove dsh-vmouse`；同样支持 `uninstall.cmd --dry-run` 预览）。

卸载后 `mcp__vmouse__*` 工具与 `virtual-mouse` skill 一起消失，常驻 PowerShell 进程会随 MCP server 退出而结束，无服务/注册表残留。link 方式安装的，卸载后可按需删除仓库目录。
