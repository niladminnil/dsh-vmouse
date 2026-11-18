<#
.SYNOPSIS
    vmouse 验证靶场：固定位置的 WinForms 窗口，用于接收/记录虚拟鼠标注入的点击。

.DESCRIPTION
    - 必须用 Windows PowerShell 5.1、-STA 运行（powershell.exe，不是 pwsh）。
    - 窗口固定在屏幕 (300,180)，大小 460x360，标题「vmouse 靶场」。
    - 控件：按钮「点我」、文本框、只读状态标签。
    - 按钮 Click / 窗口 MouseDown / 文本框 MouseDown 都会把「时间戳 + 事件 + 屏幕坐标」
      追加写入 clicks.log（UTF-8 无 BOM，行尾 \n）。
    - 窗口与控件句柄建立后（Shown + 100ms Timer 一次），把屏幕绝对物理坐标写入
      target.json：{ hwnd, pid, title, rect:{x,y,w,h}, button_center, textbox_center, alive, updated_at }
    - 默认隐藏自身控制台窗口，避免控制台挡住靶场（-KeepConsole 可保留控制台）。
    - 默认置顶（TopMost）：本机 DSH Desktop 主窗口几乎占满全屏，靶场不置顶会被盖住，
      既截不到图，注入时 WindowFromPoint 也会解析到 DSH 主窗口。用 -NoTopMost 可关闭置顶。

.PARAMETER KeepConsole
    不隐藏控制台窗口（调试用）。

.PARAMETER NoTopMost
    不置顶（默认是置顶，便于截图核对和窗口消息注入的命中判定）。

.NOTES
    启动（后台，推荐）：
        Start-Process powershell.exe -ArgumentList '-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','<仓库>\test\testtarget.ps1' -PassThru
    停止：
        Stop-Process -Id (Get-Content '<仓库>\test\target.json' -Raw | ConvertFrom-Json).pid -Force
    说明：testtarget 只接收窗口消息，不会移动真实鼠标；自测也不需要真实点击。
#>
[CmdletBinding()]
param(
    [switch]$KeepConsole,
    [switch]$NoTopMost
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:testDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:testDir)) { $script:testDir = (Split-Path -Parent $PSCommandPath) }
$script:targetPath = Join-Path $script:testDir 'target.json'
$script:logPath = Join-Path $script:testDir 'clicks.log'
$script:errorLogPath = Join-Path $script:testDir 'testtarget.error.log'
$script:utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:clickCount = 0
$script:lastDown = $null
$script:lastButtonDown = $null
$script:lastTextboxDown = $null

function Write-ErrorLog {
    param([string]$Message)
    try {
        $line = (Get-Date).ToString('o') + "`t" + $Message
        [System.IO.File]::AppendAllText($script:errorLogPath, $line + "`n", $script:utf8NoBom)
    } catch { }
}

function Write-ClickLog {
    param(
        [string]$EventName,
        [int]$X,
        [int]$Y,
        [string]$Detail = ''
    )
    $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK')
    $line = "$ts | $EventName | screen=($X,$Y)"
    if ($Detail) { $line = $line + " | " + $Detail }
    try {
        [System.IO.File]::AppendAllText($script:logPath, $line + "`n", $script:utf8NoBom)
    } catch {
        Write-ErrorLog "clicks.log 写入失败: $($_.Exception.Message)"
    }
}

function Set-Status {
    param([string]$Text)
    try { $script:status.Text = $Text } catch { }
}

function Write-TargetJson {
    param([bool]$Alive = $true)

    if (-not $script:form -or -not $script:form.IsHandleCreated) { return }

    $left = 0; $top = 0; $right = 0; $bottom = 0
    $gotRect = $false
    try {
        $rect = New-Object VMouseTest.RECT
        if ([VMouseTest.Native]::GetWindowRect($script:form.Handle, [ref]$rect)) {
            $left = $rect.Left; $top = $rect.Top
            $right = $rect.Right; $bottom = $rect.Bottom
            $gotRect = $true
        }
    } catch { }
    if (-not $gotRect) {
        $b = $script:form.Bounds
        $left = $b.X; $top = $b.Y; $right = $b.Right; $bottom = $b.Bottom
    }

    $btnCenter = $script:button.PointToScreen([System.Drawing.Point]::new(
        [int]($script:button.Width / 2), [int]($script:button.Height / 2)))
    $tbCenter = $script:textbox.PointToScreen([System.Drawing.Point]::new(
        [int]($script:textbox.Width / 2), [int]($script:textbox.Height / 2)))

    $obj = [pscustomobject]@{
        hwnd           = [int64]$script:form.Handle
        pid            = $PID
        title          = $script:form.Text
        rect           = [pscustomobject]@{
            x = [int]$left
            y = [int]$top
            w = [int]($right - $left)
            h = [int]($bottom - $top)
        }
        button_center  = [pscustomobject]@{ x = [int]$btnCenter.X; y = [int]$btnCenter.Y }
        textbox_center = [pscustomobject]@{ x = [int]$tbCenter.X; y = [int]$tbCenter.Y }
        alive          = [bool]$Alive
        updated_at     = (Get-Date).ToString('o')
    }

    $json = $obj | ConvertTo-Json -Compress -Depth 5
    [System.IO.File]::WriteAllText($script:targetPath, $json, $script:utf8NoBom)
}

try {
    if (-not (Test-Path -LiteralPath $script:testDir)) {
        [void][System.IO.Directory]::CreateDirectory($script:testDir)
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # 按 task 要求：先 EnableVisualStyles，再 DPI aware，最后才创建任何窗口/控件。
    [System.Windows.Forms.Application]::EnableVisualStyles()

    if (-not ('VMouseTest.Native' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace VMouseTest
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public static class Native
    {
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetProcessDPIAware();

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    }
}
'@
    }

    # 物理像素坐标与截图一致
    [void][VMouseTest.Native]::SetProcessDPIAware()

    if (-not $KeepConsole) {
        try {
            $consoleHwnd = [VMouseTest.Native]::GetConsoleWindow()
            if ($consoleHwnd -ne [IntPtr]::Zero) { [void][VMouseTest.Native]::ShowWindow($consoleHwnd, 0) }
        } catch { }
    }

    # 每次启动清空日志，方便 Lead 判定「本轮」是否收到点击
    [System.IO.File]::WriteAllText($script:logPath, '', $script:utf8NoBom)

    $script:form = New-Object System.Windows.Forms.Form
    $script:form.Text = 'vmouse 靶场'
    $script:form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $script:form.Location = [System.Drawing.Point]::new(300, 180)
    $script:form.Size = [System.Drawing.Size]::new(460, 360)
    $script:form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $script:form.MaximizeBox = $false
    $script:form.MinimizeBox = $false
    $script:form.ShowIcon = $false
    $script:form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $script:form.TopMost = $true
    if ($NoTopMost) { $script:form.TopMost = $false }

    $script:button = New-Object System.Windows.Forms.Button
    $script:button.Text = '点我'
    $script:button.Location = [System.Drawing.Point]::new(40, 60)
    $script:button.Size = [System.Drawing.Size]::new(160, 48)
    $script:button.Name = 'btnClickMe'

    $script:textbox = New-Object System.Windows.Forms.TextBox
    $script:textbox.Text = '文本框'
    $script:textbox.Location = [System.Drawing.Point]::new(40, 140)
    $script:textbox.Size = [System.Drawing.Size]::new(240, 28)
    $script:textbox.Name = 'txtTarget'

    $script:status = New-Object System.Windows.Forms.Label
    $script:status.Text = '等待注入事件…'
    $script:status.Location = [System.Drawing.Point]::new(40, 210)
    $script:status.Size = [System.Drawing.Size]::new(380, 90)
    $script:status.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
    $script:status.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
    $script:status.Name = 'lblStatus'

    $script:form.Controls.AddRange(@($script:button, $script:textbox, $script:status))

    # ---------- 事件记录（只写日志，不移动真实鼠标） ----------
    $script:button.Add_MouseDown({
        try {
            $pt = $script:button.PointToScreen([System.Drawing.Point]::new([int]$_.X, [int]$_.Y))
            $script:lastButtonDown = $pt
            Write-ClickLog -EventName 'button.mousedown' -X $pt.X -Y $pt.Y -Detail ("button=" + $_.Button)
            Set-Status ("按钮按下 " + $_.Button + " @ (" + $pt.X + "," + $pt.Y + ")")
        } catch { Write-ErrorLog "button.MouseDown: $($_.Exception.Message)" }
    })

    $script:button.Add_Click({
        try {
            $script:clickCount = $script:clickCount + 1
            $pt = $script:lastButtonDown
            if ($null -eq $pt) {
                $pt = $script:button.PointToScreen([System.Drawing.Point]::new(
                    [int]($script:button.Width / 2), [int]($script:button.Height / 2)))
            }
            Write-ClickLog -EventName 'button.click' -X $pt.X -Y $pt.Y -Detail ("count=" + $script:clickCount)
            Set-Status ("按钮点击 " + $script:clickCount + " 次 @ (" + $pt.X + "," + $pt.Y + ")")
        } catch { Write-ErrorLog "button.Click: $($_.Exception.Message)" }
    })

    $script:form.Add_MouseDown({
        try {
            $pt = $script:form.PointToScreen([System.Drawing.Point]::new([int]$_.X, [int]$_.Y))
            $script:lastDown = $pt
            Write-ClickLog -EventName 'window.mousedown' -X $pt.X -Y $pt.Y -Detail ("button=" + $_.Button)
            Set-Status ("窗口按下 " + $_.Button + " @ (" + $pt.X + "," + $pt.Y + ")")
        } catch { Write-ErrorLog "form.MouseDown: $($_.Exception.Message)" }
    })

    $script:textbox.Add_MouseDown({
        try {
            $pt = $script:textbox.PointToScreen([System.Drawing.Point]::new([int]$_.X, [int]$_.Y))
            $script:lastTextboxDown = $pt
            Write-ClickLog -EventName 'textbox.mousedown' -X $pt.X -Y $pt.Y -Detail ("button=" + $_.Button)
            Set-Status ("文本框按下 " + $_.Button + " @ (" + $pt.X + "," + $pt.Y + ")")
        } catch { Write-ErrorLog "textbox.MouseDown: $($_.Exception.Message)" }
    })

    # 句柄都建立后再写 target.json：Shown 里启动 100ms 单次 Timer
    $script:timer = New-Object System.Windows.Forms.Timer
    $script:timer.Interval = 100
    $script:timer.Add_Tick({
        try {
            Write-TargetJson -Alive $true
        } catch {
            Write-ErrorLog "Write-TargetJson: $($_.Exception.Message)"
        } finally {
            $script:timer.Stop()
        }
    })

    $script:form.Add_Shown({
        try { $script:timer.Start() } catch { Write-ErrorLog "timer.Start: $($_.Exception.Message)" }
    })

    $script:form.Add_FormClosing({
        try { Write-TargetJson -Alive $false } catch { }
    })

    Write-ErrorLog "start: pid=$PID dir=$($script:testDir)"

    [System.Windows.Forms.Application]::Run($script:form)

    try { Write-TargetJson -Alive $false } catch { }
    exit 0
}
catch {
    Write-ErrorLog ("FATAL: " + $_.Exception.ToString())
    try { Write-TargetJson -Alive $false } catch { }
    exit 1
}
