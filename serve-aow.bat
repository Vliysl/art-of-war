@echo off
title Art of War - Rojo Server
cd /d "%~dp0"
echo.
echo   ==================================================
echo     Art of War  -  Rojo server
echo   ==================================================
echo.
echo   Starting the live sync between your files and Studio.
echo   Keep this window OPEN while you work.
echo.
echo   In Studio:   Plugins tab  -^>  Rojo  -^>  Connect
echo.
echo   --------------------------------------------------
echo.
where rojo >nul 2>nul
if %errorlevel%==0 (
  rojo serve
) else if exist "%USERPROFILE%\.rokit\bin\rojo.exe" (
  "%USERPROFILE%\.rokit\bin\rojo.exe" serve
) else (
  echo   Rojo was not found on this computer.
  echo   Run  first-time-setup.bat  once, then try again.
)
echo.
echo   --------------------------------------------------
echo   Rojo server stopped. You can close this window.
echo.
pause
