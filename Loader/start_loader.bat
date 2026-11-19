@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title ROB RUN - official loader (updater fallback)

rem =====================================================================
rem  UNTOUCHED VENDOR CHAIN. No shim, no local api, no patched bytes:
rem     Loader.exe --official  ->  vendor api  ->  its own updater
rem  start.bat calls this only when OUR key cannot use the vendor (the
rem  hardware id is bound to one PC, or the key has run out). The official
rem  key in loader_key.txt does the login there, so the real loader stays
rem  the one that updates itself, exactly as it does for everyone else.
rem =====================================================================

set "KEYF=%~dp0loader_key.txt"
if not exist "%KEYF%" (
    echo [x] loader_key.txt is missing - cannot log in to the official loader
    exit /b 2
)

rem first non-empty, non-# line is the key
set "OKEY="
for /f "usebackq delims=" %%L in ("%KEYF%") do (
    set "LINE=%%L"
    if not "!LINE!"=="" if not "!LINE:~0,1!"=="#" set "OKEY=!LINE!"
)
if "!OKEY!"=="" (
    echo [x] loader_key.txt has no key line
    exit /b 2
)

set "HERE=%~dp0"
set "HERE=!HERE:~0,-1!"
if not exist "%HERE%\Loader.exe" (
    echo [x] Loader.exe is missing next to this file
    exit /b 3
)

echo [*] starting the official loader ...
start "" /wait "%HERE%\Loader.exe" --official --key "!OKEY!"
set "RC=!errorlevel!"
echo [*] official loader finished ^(exit=!RC!^)
exit /b !RC!