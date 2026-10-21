@echo off
REM VSCode Pocket launcher — double-click to start.
REM Closing the console window stops every service (guaranteed by a Job Object).

setlocal
set "HERE=%~dp0"
where pwsh >nul 2>nul
if errorlevel 1 (
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%HERE%scripts\Launch.ps1" %*
) else (
    pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%HERE%scripts\Launch.ps1" %*
)
if errorlevel 1 pause
endlocal
