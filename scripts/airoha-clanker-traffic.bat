@echo off
setlocal EnableExtensions DisableDelayedExpansion
rem Native Windows cmd.exe only; iperf3.exe is the traffic generator.
rem Keep this file ASCII with CRLF line endings.
set "server="
set "port=5201"
set "minutes=120"
set "block=60"
set "selected_mode=mixed"
set "rate=20"
set "tcp_rate=0"
set "udp_buffer=256"
set "output="
set "family="
set "iperf=%~dp0iperf3.exe"
set "custom_iperf="

:parse
if "%~1"=="" goto validate
if /i "%~1"=="--help" goto help
if /i "%~1"=="--ipv6" (
    set "family=-6"
    shift
    goto parse
)
if "%~2"=="" goto usage_error
if /i "%~1"=="--server" (
    set "server=%~2"
    shift
    shift
    goto parse
)
if /i "%~1"=="--mode" (
    set "selected_mode=%~2"
    shift
    shift
    goto parse
)
if /i "%~1"=="--port" (
    set "port=%~2"
    shift
    shift
    goto parse
)
if /i "%~1"=="--minutes" (
    set "minutes=%~2"
    shift
    shift
    goto parse
)
if /i "%~1"=="--block" (
    set "block=%~2"
    shift
    shift
    goto parse
)
if /i "%~1"=="--udp-mbps" (
    set "rate=%~2"
    shift
    shift
    goto parse
)
if /i "%~1"=="--tcp-mbps" (
    set "tcp_rate=%~2"
    shift
    shift
    goto parse
)
if /i "%~1"=="--udp-buffer-kb" (
    set "udp_buffer=%~2"
    shift
    shift
    goto parse
)
if /i "%~1"=="--output" (
    set "output=%~2"
    shift
    shift
    goto parse
)
if /i "%~1"=="--iperf" (
    set "iperf=%~2"
    set "custom_iperf=1"
    shift
    shift
    goto parse
)
goto usage_error

:validate
setlocal EnableDelayedExpansion
if not defined server goto usage_error
if not defined output goto usage_error
rem Restrict numeric syntax before SET /A (no expressions or octal numbers).
for %%V in (port minutes block rate udp_buffer tcp_rate) do (
    if not defined %%V goto usage_error
    for /f "delims=0123456789" %%B in ("!%%V!") do goto usage_error
    set "number=!%%V!"
    if "!number:~0,1!"=="0" if not "%%V=!number!"=="tcp_rate=0" goto usage_error
    if not "!number:~5!"=="" goto usage_error
)
if !port! GTR 65535 goto usage_error
if !minutes! GTR 120 goto usage_error
if !block! LSS 5 goto usage_error
if !block! GTR 600 goto usage_error
if !rate! GTR 10000 goto usage_error
if !tcp_rate! GTR 10000 goto usage_error
set "valid_mode="
for %%M in (mixed tcp-both tcp-download tcp-upload udp-download udp-upload-small) do if /i "!selected_mode!"=="%%M" set "valid_mode=1"
if not defined valid_mode goto usage_error
set "tcp_limit="
if !tcp_rate! GTR 0 (
    rem iperf3 -b applies per stream; four streams share the requested total.
    set /a "tcp_stream_kbps=tcp_rate*250" >nul
    set "tcp_limit=-b !tcp_stream_kbps!K"
)
if !udp_buffer! LSS 16 goto usage_error
if !udp_buffer! GTR 2048 goto usage_error
rem Hostname, IPv4 or unbracketed IPv6; quote paths that contain spaces.
for /f "delims=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-_%%" %%B in ("!server!") do goto usage_error
if "!server:~0,1!"=="-" goto usage_error
if exist "!output!" (
    echo ERROR: Output already exists: "!output!"
    exit /b 2
)
if defined custom_iperf goto check_iperf
if exist "!iperf!" goto check_iperf
set "iperf=iperf3.exe"

:check_iperf
"!iperf!" --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Cannot run iperf3.exe. Place it beside this BAT or use --iperf "C:\path\iperf3.exe".
    exit /b 2
)
mkdir "!output!" 2>nul
if errorlevel 1 (
    echo ERROR: Cannot create a new output directory: "!output!"
    exit /b 2
)
rem Use a file, not a pipe: CMD pipe subprocesses do not inherit delayed expansion.
rem Preserve the available options when rejecting an incompatible iperf build.
"!iperf!" --help >"!output!\iperf-help.txt" 2>&1
findstr /l /c:"--connect-timeout" "!output!\iperf-help.txt" >nul
if errorlevel 1 goto old_iperf
findstr /l /c:"--rcv-timeout" "!output!\iperf-help.txt" >nul
if errorlevel 1 goto old_iperf

set /a "limit=minutes*60,blocks=0,failures=0,elapsed=0"
set "status=running"
set "started=!date! !time!"
call :clock
set "start_tick=!tick!"
>"!output!\manifest.txt" (
    echo schema=4
    echo selected_mode=!selected_mode!
    echo runner=airoha-clanker-traffic.bat
    echo server=!server!
    echo port=!port!
    echo requested_minutes=!minutes!
    echo block_seconds=!block!
    echo udp_mbps=!rate!
    echo tcp_total_mbps=!tcp_rate!
    echo tcp_parallel_streams=4
    echo udp_buffer_kb=!udp_buffer!
    echo ip_family=!family!
    echo started_local=!started!
    echo clock=local wall clock; do not change the PC clock during the run
    echo connect_timeout_ms=3000
    echo receive_timeout_ms=10000; receiving modes only
)
"!iperf!" --version >"!output!\iperf-version.txt" 2>&1
ver >"!output!\windows-version.txt" 2>&1
netsh wlan show interfaces >"!output!\wlan-interfaces.txt" 2>&1
netsh wlan show drivers >"!output!\wlan-drivers.txt" 2>&1
>"!output!\results.csv" echo index,mode,elapsed_start_seconds,duration_requested_seconds,elapsed_end_seconds,exit_code,result,json_file,stderr_file,error_class
call :summary
echo Running for !minutes! minutes. Results: "!output!"
echo To stop after the current block, create an empty STOP file in that directory.
echo Ctrl+C may skip the final summary; completed block files are retained.

:next
call :elapsed
if exist "!output!\STOP" (
    set "status=stopped_early"
    goto finish
)
set /a "remaining=limit-elapsed"
if !remaining! LEQ 0 (
    set "status=complete"
    goto finish
)
if !remaining! LSS 5 (
    set "delay=!remaining!"
    call :pause
    goto next
)
set /a "duration=block,mode=blocks%%4,blocks+=1,block_start=elapsed"
if !duration! GTR !remaining! set "duration=!remaining!"
if /i "!selected_mode!"=="tcp-both" set /a "mode=(blocks-1)%%2" >nul
if /i "!selected_mode!"=="tcp-download" set "mode=0"
if /i "!selected_mode!"=="tcp-upload" set "mode=1"
if /i "!selected_mode!"=="udp-download" set "mode=2"
if /i "!selected_mode!"=="udp-upload-small" set "mode=3"
if !mode! EQU 0 (
    set "name=tcp-download"
    set "extra=-R -P 4 !tcp_limit! --rcv-timeout 10000"
)
if !mode! EQU 1 (
    set "name=tcp-upload"
    set "extra=-P 4 !tcp_limit!"
)
if !mode! EQU 2 (
    set "name=udp-download"
    set "extra=-R -u -b !rate!M -l 1200 -w !udp_buffer!K --rcv-timeout 10000"
)
if !mode! EQU 3 (
    set "name=udp-upload-small"
    set "extra=-u -b !rate!M -l 128 -w !udp_buffer!K"
)
set "stem=block-!blocks!-!name!"
>"!output!\current.txt" (
    echo block=!blocks! mode=!name! started_local=!date! !time!
    echo status=running
)
echo [!date! !time!] !blocks!: !name! for !duration! seconds
"!iperf!" -c "!server!" -p !port! !family! -J -i 0 -t !duration! --connect-timeout 3000 !extra! >"!output!\!stem!.json" 2>"!output!\!stem!.stderr.txt"
set "rc=!errorlevel!"
set "result=COMPLETE"
set "parameter_error=0"
if not "!rc!"=="0" set "result=FAIL"
rem Retain iperf's original JSON, including any error object.
findstr /l /c:"\"error\"" "!output!\!stem!.json" >nul 2>&1
if not errorlevel 1 set "result=FAIL"
for %%F in ("!output!\!stem!.json") do if %%~zF EQU 0 set "result=FAIL"
findstr /l /c:"parameter error" "!output!\!stem!.stderr.txt" >nul 2>&1
if not errorlevel 1 (
    set "parameter_error=1"
    set "result=FAIL"
)
if "!result!"=="FAIL" set /a "failures+=1" >nul
call :elapsed
set "error_class=none"
if "!result!"=="FAIL" call :failure
call :elapsed
>>"!output!\results.csv" echo !blocks!,!name!,!block_start!,!duration!,!elapsed!,!rc!,!result!,!stem!.json,!stem!.stderr.txt,!error_class!
>"!output!\current.txt" echo block=!blocks! mode=!name! status=!result! finished_local=!date! !time!
call :summary
echo   !result!; elapsed !elapsed! s; failed blocks !failures!/!blocks!
if "!parameter_error!"=="1" (
    set "status=setup_failed_parameter"
    goto finish
)
if exist "!output!\STOP" goto next
if !elapsed! GEQ !limit! goto next
rem One-second gap, or five seconds after a failed connection; no tight retry loop.
set "delay=1"
if "!result!"=="FAIL" set "delay=5"
if "!error_class!"=="server_busy" set "delay=15"
call :pause
goto next

:failure
set "error_class=process_or_protocol"
for %%E in ("Network is unreachable" "Connection timed out" "Connection reset by peer" "server is busy") do (
    findstr /i /l /c:%%E "!output!\!stem!.json" "!output!\!stem!.stderr.txt" >nul 2>&1
    if not errorlevel 1 (
        if %%E=="Network is unreachable" set "error_class=network_unreachable"
        if %%E=="Connection timed out" set "error_class=connect_timeout"
        if %%E=="Connection reset by peer" set "error_class=connection_reset"
        if %%E=="server is busy" set "error_class=server_busy"
    )
)
if "!rc!"=="-1073741819" set "error_class=client_access_violation"
rem Collect a bounded snapshot at most once per 30 seconds; retain every error.
if defined last_failure_snapshot (
    set /a "since_snapshot=elapsed-last_failure_snapshot"
    if !since_snapshot! LSS 30 exit /b
)
set "last_failure_snapshot=!elapsed!"
>"!output!\!stem!.network.txt" (
    echo local=!date! !time! elapsed=!elapsed! error_class=!error_class!
    ping -n 2 -w 1000 "!server!"
    ipconfig
    route print -4
    netsh wlan show interfaces
)
exit /b

:pause
timeout /t !delay! /nobreak >nul 2>&1
if errorlevel 1 (
    set /a "pings=delay+1"
    ping -n !pings! 127.0.0.1 >nul 2>&1
)
exit /b

:finish
call :summary
echo Finished: !status!; !blocks! blocks, !failures! failed; !elapsed! seconds.
echo Match failed blocks to recovery events and inspect the JSON for throughput, loss and jitter.
if "!status!"=="setup_failed_parameter" exit /b 2
if "!status!"=="stopped_early" exit /b 3
if !blocks! EQU 0 exit /b 1
if !failures! GTR 0 exit /b 1
exit /b 0

:clock
rem TIME is HH:mm:ss.cc, sometimes with a leading space for hours below 10.
set "clock_value=!time: =0!"
set /a "tick=(1!clock_value:~0,2!-100)*3600+(1!clock_value:~3,2!-100)*60+(1!clock_value:~6,2!-100)" >nul
exit /b

:elapsed
call :clock
set /a "elapsed=tick-start_tick" >nul
if !elapsed! LSS 0 set /a "elapsed+=86400" >nul
exit /b

:summary
>"!output!\summary.txt" (
    echo status=!status!
    echo requested_minutes=!minutes!
    echo elapsed_seconds=!elapsed!
    echo blocks=!blocks!
    echo failed_blocks=!failures!
    echo updated_local=!date! !time!
    echo note=Planned recovery failures are retained. This is not an automatic acceptance verdict.
)
exit /b

:old_iperf
echo ERROR: This iperf3 must support --connect-timeout and --rcv-timeout. Use a current Windows build.
>"!output!\summary.txt" echo status=setup_failed_incompatible_iperf
exit /b 2

:usage_error
echo ERROR: Invalid or missing arguments. Use --help for syntax.
exit /b 2

:help
echo Usage: %~nx0 --server HOST --output NEW_DIR [options]
echo.
echo   --mode NAME       mixed, tcp-both, tcp-download, tcp-upload, udp-download, udp-upload-small
echo   --port N          Server port, 1..65535, default 5201
echo   --minutes N       Wall-clock duration, 1..120, default 120
echo   --block N         Seconds per block, 5..600, default 60
echo   --tcp-mbps N      Total target for four TCP streams, 0..10000, default 0=unlimited
echo   --udp-mbps N      Integer UDP Mbps, 1..10000, default 20
echo   --udp-buffer-kb N UDP socket buffer KiB, 16..2048, default 256
echo   --ipv6            Use IPv6; supply an unbracketed IPv6 address
echo   --iperf PATH      Full path to iperf3.exe; default beside BAT, then PATH
echo.
echo Integers must not have leading zeros. Quote paths containing spaces.
echo Alternates TCP download/upload, UDP 1200-byte download and UDP 128-byte upload.
echo COMPLETE means the process finished; check JSON for actual UDP loss and throughput.
echo Results: manifest, CSV, summary, per-block JSON/stderr and Windows WLAN information.
echo Output must be a NEW directory. STOP ends after the current block.
echo Exit codes: 0=complete/no failed blocks, 1=failed blocks, 2=setup, 3=STOP.
exit /b 0
