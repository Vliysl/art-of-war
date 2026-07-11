@echo off
title Art of War - Rojo Server (OBFUSCATED release tree)
cd /d "%~dp0"
echo.
echo   ==================================================
echo     Art of War  -  Rojo server (OBFUSCATED)
echo   ==================================================
echo.
echo   Building the obfuscated client tree, then serving
echo   it to Studio. Use this ONLY for release publishes;
echo   for day-to-day work use serve-aow.bat instead.
echo.
echo   In Studio:   Plugins tab  -^>  Rojo  -^>  Connect
echo   Then:        File  -^>  Publish to Roblox
echo.
echo   --------------------------------------------------
echo.

set "LUNE_CMD=lune"
where lune >nul 2>nul
if not %errorlevel%==0 (
  if exist "%USERPROFILE%\.rokit\bin\lune.exe" (
    set "LUNE_CMD=%USERPROFILE%\.rokit\bin\lune.exe"
  ) else (
    echo   Lune was not found on this computer.
    echo   Run  first-time-setup.bat  once, then try again.
    goto :end
  )
)

"%LUNE_CMD%" run tools/obfuscate
if not %errorlevel%==0 (
  echo.
  echo   Obfuscation FAILED - nothing is being served.
  echo   Fix the error above and run this again.
  goto :end
)

echo.
echo   --------------------------------------------------
echo.

where rojo >nul 2>nul
if %errorlevel%==0 (
  rojo serve build/release.project.json
) else if exist "%USERPROFILE%\.rokit\bin\rojo.exe" (
  "%USERPROFILE%\.rokit\bin\rojo.exe" serve build/release.project.json
) else (
  echo   Rojo was not found on this computer.
  echo   Run  first-time-setup.bat  once, then try again.
)

:end
echo.
echo   --------------------------------------------------
echo   Rojo server stopped. You can close this window.
echo.
pause
