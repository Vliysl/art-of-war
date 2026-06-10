@echo off
title Art of War - First-Time Setup
cd /d "%~dp0"
echo.
echo   ==================================================
echo     Art of War  -  first-time setup   (run once)
echo   ==================================================
echo.
echo   This prepares this folder on YOUR computer:
echo     - your commits will be credited to avierns-dev
echo     - the toolchain (Rojo, Lune, ...) gets installed
echo.
set /p ok=  Continue?  (y/n):
if /i not "%ok%"=="y" (
  echo.
  echo   Cancelled - nothing was changed.
  echo.
  pause
  exit /b
)
echo.
echo   [1 of 3]  Setting your commit identity...
git config user.name "Avierns"
git config user.email "292048751+avierns-dev@users.noreply.github.com"
echo            commits from here will show as:  Avierns (avierns-dev)
echo.
echo   [2 of 3]  Installing the toolchain via Rokit...
where rokit >nul 2>nul
if %errorlevel% neq 0 (
  echo            Rokit isn't installed yet.
  echo            Install it from  https://github.com/rojo-rbx/rokit
  echo            then run this file again.
  echo.
  pause
  exit /b
)
rokit install
echo.
echo   [3 of 3]  Checking Rojo...
where rojo >nul 2>nul && rojo --version || "%USERPROFILE%\.rokit\bin\rojo.exe" --version
echo.
echo   ==================================================
echo     Setup complete.
echo     Next: open the place in Studio, then double-click
echo           serve-aow.bat  to start working.
echo   ==================================================
echo.
pause
