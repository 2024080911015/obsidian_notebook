@echo off
rem TrafficMonitor launcher -- double click to view usage, or pass arguments.
rem Examples:
rem   TrafficMonitor.cmd                    (show usage)
rem   TrafficMonitor.cmd -Action report -Days 30
rem   TrafficMonitor.cmd -Action install
setlocal
set "SCRIPT=%~dp0TrafficMonitor.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "CODE=%ERRORLEVEL%"
if not "%CODE%"=="0" echo [exit code: %CODE%]
if "%~1"=="" pause
endlocal
