@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
title dsh-vmouse 安装
set "PROFILE_ARG=desktop"
if not "%DSH_PROFILE%"=="" set "PROFILE_ARG=%DSH_PROFILE%"

echo [dsh-vmouse] 目标 DSH profile: %PROFILE_ARG%
echo [dsh-vmouse] 安装目录: %~dp0

if /I "%~1"=="--dry-run" (
  echo [dry-run] 将执行: dsh plugin --profile %PROFILE_ARG% add "link:%~dp0"
  exit /b 0
)

tasklist /FI "IMAGENAME eq DSH Desktop.exe" 2>nul | find /I "DSH Desktop.exe" >nul
if not errorlevel 1 (
  echo.
  echo [dsh-vmouse] DSH Desktop 正在运行，安装前必须完全退出它。
  echo               也可以改用 README 里的「让 agent 安装」方式（无需退出）。
  exit /b 1
)

where dsh >nul 2>nul
if errorlevel 1 (
  echo.
  echo [dsh-vmouse] 找不到 dsh 命令。请改用 README 里的「让 agent 安装」方式，
  echo               或在 DSH 的 host-commands 目录里找到 dsh.cmd 后把本脚本里的 dsh 换成它的完整路径。
  exit /b 1
)

echo [dsh-vmouse] 正在安装...
dsh plugin --profile %PROFILE_ARG% add "link:%~dp0"
if errorlevel 1 (
  echo.
  echo [dsh-vmouse] 安装失败，请把上面的错误信息发给 DSH agent 排查。
  exit /b 1
)

echo.
echo [dsh-vmouse] 安装完成。请重新打开 DSH Desktop，
echo               在「设置 - 插件」里确认出现「虚拟鼠标（agent 自己的光标）」。
echo               验证：让 agent 调用 mcp__vmouse__status 或 mcp__vmouse__move。
endlocal