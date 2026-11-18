@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "RUN=%ROOT%\run"
set "PS1=%ROOT%\tools\123.ps1"
set "PS_FLAGS="
set "NO_CLIENT="
set "FIX_BLOCKLIST="
:parse
if "%~1"=="" goto after_parse
if /i "%~1"=="--s" set "PS_FLAGS=%PS_FLAGS% -Session" & shift & goto parse
if /i "%~1"=="--u" set "PS_FLAGS=%PS_FLAGS% -UnsafeFull" & shift & goto parse
if /i "%~1"=="--i" set "PS_FLAGS=%PS_FLAGS% -PatchIntel" & shift & goto parse
if /i "%~1"=="--n" set "NO_CLIENT=1" & shift & goto parse
if /i "%~1"=="--b" set "FIX_BLOCKLIST=1" & shift & goto parse
if /i "%~1"=="--r" goto do_restore
if /i "%~1"=="-h" goto usage
if /i "%~1"=="--help" goto usage
echo [warn] unknown option: %~1
goto usage
:after_parse
net session >nul 2>&1
if not errorlevel 1 goto admin_ok
if not "%~1"=="" goto elevate_args
echo [*] requesting administrator rights...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" 2>nul
exit /b
:elevate_args
echo [*] requesting administrator rights...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs" 2>nul
exit /b
:admin_ok
if exist "%PS1%" goto ps1_ok
echo [-] missing: "%PS1%"
goto fail
:ps1_ok
if not defined FIX_BLOCKLIST goto blocklist_check
reg add "HKLM\SYSTEM\CurrentControlSet\Control\CI\Config" /v VulnerableDriverBlocklistEnable /t REG_DWORD /d 0 /f >nul 2>&1
if errorlevel 1 goto blocklist_failed
echo [+] reg ok
echo [warn] reboot required
goto blocklist_check
:blocklist_failed
echo [-] reg write failed
:blocklist_check
set "BL="
for /f "tokens=3" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\CI\Config" /v VulnerableDriverBlocklistEnable 2^>nul ^| findstr /i VulnerableDriverBlocklistEnable') do set "BL=%%A"
if not defined BL goto blocklist_done
if "!BL!"=="0x0" goto blocklist_done
echo [warn] blocklist on: !BL!
:blocklist_done
if not defined FIX_BLOCKLIST goto patch_stage
echo [warn] reboot, then run again
endlocal
exit /b 0
:patch_stage
echo [*] stage...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Root "%ROOT%" %PS_FLAGS%
if errorlevel 1 goto fail
if not exist "%TEMP%\focus.key" goto key_clean
del /f /q "%TEMP%\focus.key" >nul 2>&1
:key_clean
echo [*] start...
pushd "%RUN%"
start "" /b "%RUN%\mapper.exe" "%RUN%\123.sys" "%RUN%\driver.sys"
popd
echo [*] wait...
set "WAIT=0"
:wait_key
if exist "%TEMP%\focus.key" goto have_key
set /a WAIT+=1
if !WAIT! GEQ 30 goto no_key
ping -n 2 127.0.0.1 >nul
goto wait_key
:have_key
echo [+] ok
goto client
:no_key
echo [warn] timeout
:client
if defined NO_CLIENT goto done
if exist "%RUN%\123.exe" goto client_ok
goto done
:client_ok
tasklist /fi "imagename eq 123.exe" 2>nul | find /i "123.exe" >nul
if not errorlevel 1 goto client_running
echo [*] client...
pushd "%RUN%"
start "" "%RUN%\123.exe"
popd
goto done
:client_running
echo [+] running
:done
echo [+] end
endlocal
exit /b 0
:do_restore
net session >nul 2>&1
if not errorlevel 1 goto restore_admin
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '--r' -Verb RunAs" 2>nul
exit /b
:restore_admin
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Root "%ROOT%" -Restore
endlocal
exit /b 0
:usage
echo.
echo   start.bat [options]
echo.
echo   --s   state checks
echo   --u   full (bugcheck risk)
echo   --i   intel patch
echo   --n   driver only
echo   --b   blocklist off (reboot)
echo   --r   restore
echo.
endlocal
exit /b 1
:fail
echo [-] fail
endlocal
exit /b 1