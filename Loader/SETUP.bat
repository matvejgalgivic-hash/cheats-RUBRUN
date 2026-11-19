@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title crack - armore3 setup
chcp 65001 >nul

rem =====================================================================
rem  First-run check for THIS PC.
rem
rem  The crack itself (api.py + LoaderCrack.exe) accepts any key locally,
rem  but the RUNTIME ticket is minted with the real vendor, and the vendor
rem  binds a key to ONE hardware id. So:
rem    * on armore3's PC  -> everything works, updates come straight from
rem                          the vendor through update.ps1;
rem    * on another PC    -> the vendor refuses our key (403), the official
rem                          loader takes over the update (start_loader.bat),
rem                          and the folder still launches - it just cannot
rem                          mint a real ticket with someone else's key.
rem  This script does not pretend otherwise. It checks the machine and says
rem  exactly which mode it is in.
rem =====================================================================

set "HERE=%~dp0"
set "HERE=!HERE:~0,-1!"
set "FAIL=0"
set "WARNED=0"
set "NOPAUSE=0"
if /I "%~1"=="nopause" set "NOPAUSE=1"

echo.
echo   crack BY armore3
echo   ============================================================
echo   ROB RUN - setup check for this PC
echo   ============================================================
echo.

rem ---------------------------------------------------------------- python
echo [*] python ...
where python.exe >nul 2>nul
if errorlevel 1 (
    echo [x] Python not found in PATH.
    echo     Install Python 3.x from python.org, tick "Add python.exe to PATH",
    echo     then run SETUP.bat again.
    set "FAIL=1"
) else (
    for /f "delims=" %%V in ('python -c "import sys;print(sys.version.split()[0])" 2^>nul') do set "PYVER=%%V"
    echo [+] python !PYVER!
    where pythonw.exe >nul 2>nul
    if errorlevel 1 (
        echo [!] pythonw.exe not found - start.bat will fall back to python
        echo     and keep a console window open behind the server.
        set "WARNED=1"
    ) else (
        echo [+] pythonw.exe ok
    )
)

rem ------------------------------------------------------------- webview2
echo [*] Microsoft Edge WebView2 runtime ...
set "WV2="
for %%K in (
    "HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    "HKLM\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    "HKCU\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
) do (
    if not defined WV2 (
        for /f "tokens=2,*" %%A in ('reg query %%K /v pv 2^>nul ^| find /I "pv"') do set "WV2=%%B"
    )
)
if defined WV2 (
    echo [+] WebView2 !WV2!
) else (
    echo [!] WebView2 runtime not detected.
    echo     Loader.exe is a WebView2 app. If its window stays blank, install
    echo     the Evergreen runtime:
    echo     https://developer.microsoft.com/microsoft-edge/webview2/
    set "WARNED=1"
)

rem ---------------------------------------------------------------- files
echo [*] files ...
for %%F in (Loader.exe LoaderCrack.exe api.py inject.ps1 update.ps1 attach.ps1 start_loader.bat) do (
    if exist "%HERE%\%%F" (
        echo     ok   %%F
    ) else (
        echo [x]  missing %%F
        set "FAIL=1"
    )
)
if exist "%HERE%\packages\1.zip" (
    for %%S in ("%HERE%\packages\1.zip") do echo     ok   packages\1.zip  %%~zS bytes
) else (
    echo [x]  missing packages\1.zip  - start.bat cannot inject without it
    set "FAIL=1"
)

rem ---------------------------------------------------------------- hwid
echo [*] hardware id for this PC ...
set "HW="
if exist "%HERE%\hwid.txt" (
    for /f "usebackq delims=" %%L in ("%HERE%\hwid.txt") do (
        if not defined HW set "HW=%%L"
    )
)
if defined HW (
    echo [+] hwid.txt: !HW!
) else (
    if exist "%HERE%\logs\loader_hwid.txt" (
        for /f "usebackq delims=" %%L in ("%HERE%\logs\loader_hwid.txt") do (
            if not defined HW set "HW=%%L"
        )
        >"%HERE%\hwid.txt" echo !HW!
        echo [+] hwid.txt created from the loader's own id: !HW!
    ) else (
        echo [!] hwid.txt is empty.
        echo     The ORIGINAL loader computes this id itself and sends it to
        echo     api.py on the first login; api.py writes it to
        echo     logs\loader_hwid.txt, and the next SETUP.bat copies it here.
        echo     Nothing else is needed - just run start.bat once.
        set "WARNED=1"
    )
)

rem ---------------------------------------------------------------- licence
echo [*] licence ...
if exist "%HERE%\license.json" (
    echo     ok   license.json
) else (
    echo [x]  missing license.json - put {"key":"...."} in it
    set "FAIL=1"
)

echo.
if "!FAIL!"=="1" (
    echo [x] setup found problems - fix them before start.bat.
    echo.
    if "!NOPAUSE!"=="0" pause
    exit /b 1
)

rem --------------------------------------------------- live update check
echo [*] asking the vendor for the current build ...
echo     This is read-only: it never downloads or replaces the package.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -NoLogo -File "%HERE%\update.ps1" -Check
set "URC=!errorlevel!"
echo.
if "!URC!"=="0" (
    echo [+] update check ok - start.bat updates automatically.
) else (
    if "!URC!"=="2" (
        echo [!] this key cannot use the vendor on this PC.
        echo     Expected on any PC except armore3's: the key is bound to one
        echo     hardware id. start.bat will hand the update to the official
        echo     loader - put the official key in loader_key.txt for that.
    ) else (
        echo [!] vendor check rc=!URC! - network or backend hiccup.
        echo     start.bat still launches the installed build; it just will
        echo     not update this time.
    )
    set "WARNED=1"
)

echo.
if "!WARNED!"=="1" (
    echo [!] done with warnings - see the notes above.
) else (
    echo [+] this PC is ready.
)
echo.
echo   now run:  start.bat
echo.
if "!NOPAUSE!"=="0" pause
exit /b 0
