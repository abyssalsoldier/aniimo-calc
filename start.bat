@echo off
rem Starts the calculator. Usage: start.bat [port]
rem Port defaults to %ANIIMO_PORT% if set, otherwise 8080.
if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.ps1" -Port %1
)
pause
