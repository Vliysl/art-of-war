@echo off
title Art of War - Save to GitHub
cd /d "%~dp0"
echo.
echo   ==================================================
echo     Art of War  -  save your work to GitHub
echo   ==================================================
echo.
git add -A
git diff --cached --quiet
if %errorlevel%==0 (
  echo   Nothing to save - you're already up to date.
  echo.
  pause
  exit /b
)
echo   Changes to save:
git status --short
echo.
set /p msg=  Describe your change (or just press Enter):
if "%msg%"=="" set msg=Update from Avierns
git commit -m "%msg%" >nul
echo.
echo   Getting Vernal's latest changes first...
git pull --rebase origin main
if %errorlevel% neq 0 (
  git rebase --abort >nul 2>nul
  echo.
  echo   Heads up: your change overlaps something Vernal edited.
  echo   Easiest fix - tell your Claude:  "pull, resolve conflicts, and push"
  echo   Your commit is safe; nothing was lost.
  echo.
  pause
  exit /b
)
echo   Pushing to GitHub...
git push
echo.
echo   Done - your work is on GitHub as avierns-dev.
echo.
pause
