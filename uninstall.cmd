@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
title dsh-vmouse 卸载
set "PROFILE_ARG=desktop"
if not "%DSH_PROFILE%"=="" set "PROFILE_ARG=%DSH_PROFILE%"

if /I "%~1"=="--dry-run" (
  echo [dry-run] 将执行: dsh plugin --profile %PROFILE_ARG% remove dsh-vmouse
  exit /b 0
)

tasklist /FI "IMAGENAME eq DSH Desktop.exe" 2>nul | find /I "DSH Desktop.exe" >nul
if not errorlevel 1 (
  echo [dsh-vmouse] DSH Desktop 正在运行，请先完全退出它再卸载。
  exit /b 1
)

where dsh >nul 2>nul
if errorlevel 1 (
  echo [dsh-vmouse] 找不到 dsh 命令，请改用 agent（plugin_manager 的 remove_bundle）卸载。
  exit /b 1
)

dsh plugin --profile %PROFILE_ARG% remove dsh-vmouse
if errorlevel 1 (
  echo [dsh-vmouse] 卸载失败，请把错误信息发给 DSH agent 排查。
  exit /b 1
)
echo [dsh-vmouse] 已卸载。重新打开 DSH Desktop 后生效。
endlocal