@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem Pure cmd.exe wrapper: one iperf test per process, separate logs, no global kill.
set "port=%~1"
set "output=%~2"
set "iperf=%~dp0iperf3.exe"
if not "%~3"=="" set "iperf=%~3"
if not defined port goto usage
if not defined output goto usage
for /f "delims=0123456789" %%B in ("!port!") do goto usage
if "!port:~0,1!"=="0" goto usage
if not "!port:~5!"=="" goto usage
if !port! GTR 65535 goto usage
if exist "!output!" goto usage
"!iperf!" --version >nul 2>&1
if errorlevel 1 exit /b 2
mkdir "!output!" 2>nul
if errorlevel 1 exit /b 2
"!iperf!" --help >"!output!\iperf-help.txt" 2>&1
for %%O in (--one-off --idle-timeout --rcv-timeout --forceflush) do (
    findstr /l /c:"%%O" "!output!\iperf-help.txt" >nul
    if errorlevel 1 (
        echo ERROR: iperf3 lacks %%O. Update the server executable.
        exit /b 2
    )
)
"!iperf!" --version >"!output!\iperf-version.txt" 2>&1
set "max_duration="
findstr /l /c:"--server-max-duration" "!output!\iperf-help.txt" >nul
if not errorlevel 1 set "max_duration=--server-max-duration 90"
>"!output!\manifest.txt" (
    echo schema=1 port=!port! block_limit=60 recommended_minutes=1..120
    echo receiver_idle_timeout_ms=10000 listener_idle_timeout_seconds=30
    echo server_duration_option=!max_duration!
    echo note=Old builds have no hard reverse-sender timeout. Idle timeout is not an active-test watchdog.
)
>"!output!\sessions.csv" echo session,exit_code,finished_local
set /a "session=0"
:next
if exist "!output!\STOP" exit /b 0
set /a "session+=1"
echo [!date! !time!] Waiting for session !session! on port !port!
>"!output!\current.txt" echo session=!session! start=!date! !time!
"!iperf!" -s -1 -p !port! --idle-timeout 30 --rcv-timeout 10000 --forceflush !max_duration! -i 5 >"!output!\session-!session!.log" 2>&1
set "rc=!errorlevel!"
>>"!output!\sessions.csv" echo !session!,!rc!,!date! !time!
if not "!rc!"=="0" (
    timeout /t 2 /nobreak >nul 2>&1
    if errorlevel 1 ping -n 3 127.0.0.1 >nul
)
goto next
:usage
echo Usage: %~nx0 PORT NEW_LOG_DIR [PATH_TO_IPERF3.EXE]
echo Use one window per client, ports 5201 and 5202. Client blocks must be at most 60 seconds.
echo STOP ends after current session; Ctrl+C exits. Keep all logs before restarting a stuck server.
exit /b 2
