@echo off
setlocal
cd /d "%~dp0"
if "%~1"=="" (
    if exist "%~dp0..\payload\" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-VSCodeBeautyOneClick.ps1" -PayloadPath "%~dp0.."
    ) else (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-VSCodeBeautyOneClick.ps1"
    )
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-VSCodeBeautyOneClick.ps1" %*
)
set "beauty_exit=%errorlevel%"
echo.
pause
exit /b %beauty_exit%
