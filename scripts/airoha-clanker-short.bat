@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem Native CMD only. Main throughput parameters match the r62 baseline.
set "mode=%~1"
set "server=%~2"
set "output=%~3"
set "iperf=%~dp0iperf3.exe"
if not "%~4"=="" set "iperf=%~4"
if not defined server goto usage
if not defined output goto usage
set "topology=%~5"
if not defined topology set "topology=unspecified"
if not "%~6"=="" goto usage
set "topology_ok="
for %%T in (wan lan unspecified) do if /i "!topology!"=="%%T" set "topology_ok=1"
if not defined topology_ok goto usage
set "valid="
for %%M in (5g 2g tcp wired p4) do if /i "!mode!"=="%%M" set "valid=1"
if not defined valid goto usage
rem Test uses the existing IPv4 topology, not arbitrary shell/host input.
for /f "delims=0123456789." %%B in ("!server!") do goto usage
if exist "!output!" (
 echo ERROR: Use a NEW output directory. Existing logs are preserved.
 exit /b 2
)
if not exist "!iperf!" if "%~4"=="" set "iperf=iperf3.exe"
"!iperf!" --version >nul 2>&1
if errorlevel 1 (
 echo ERROR: Place iperf3.exe beside this BAT, on PATH, or pass its full path.
 exit /b 2
)
mkdir "!output!" 2>nul
if errorlevel 1 exit /b 2
"!iperf!" --version >"!output!\version.txt" 2>&1
"!iperf!" --help >"!output!\help.txt" 2>&1
findstr /l /c:"--get-server-output" "!output!\help.txt" >nul
if errorlevel 1 (
 echo ERROR: This iperf3 does not support --get-server-output. Keep help.txt.
 exit /b 2
)
set "limits="
findstr /l /c:"--connect-timeout" "!output!\help.txt" >nul
if not errorlevel 1 set "limits=!limits! --connect-timeout 5000"
set "markers=manual"
if defined CLANKER_ROUTER (
 if not defined CLANKER_ROUTER_DIR (
  echo ERROR: Set CLANKER_ROUTER_DIR to the active router recorder directory.
  exit /b 2
 )
 for /f "delims=0123456789." %%V in ("!CLANKER_ROUTER!") do goto usage
 for /f "delims=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-" %%V in ("!CLANKER_ROUTER_DIR!") do goto usage
 call :router_preflight
 if errorlevel 1 exit /b 2
 set "markers=automatic_ssh_uptime"
) else (
 echo WARNING: Router window markers require manual --mark commands. See test document.
)
ver >"!output!\windows.txt"
ipconfig >"!output!\address.txt"
route print !server! >"!output!\route-to-server.txt" 2>&1
netsh wlan show interfaces >"!output!\link-before.txt" 2>&1
netsh wlan show drivers >"!output!\drivers.txt" 2>&1
netstat -s -p tcp >"!output!\tcp-before.txt" 2>&1
>"!output!\manifest.txt" (
 echo schema=79 mode=!mode! server=!server! port=5201 topology=!topology!
 echo topology_source=operator_label; actual_path_requires_router_and_address_evidence
 echo begin_local=!DATE! !TIME!
 echo router_markers=!markers!
 echo connect_receive_options=!limits!
 echo power_mode=unchanged; RF_settings=unchanged; batch=16
 echo tcp_statistics=system-wide background-inclusive; not flow retransmission proof
)
if /i "!mode!"=="wired" (
 call :wired_metadata client-before
 call :run forward-p1 -P 1 -t 60 -O 5
 if errorlevel 1 goto failed
 timeout /t 5 /nobreak >nul
 call :run reverse-p1 -R -P 1 -t 60 -O 5
 if errorlevel 1 goto failed
 timeout /t 5 /nobreak >nul
 call :run forward-p4 -P 4 -t 60 -O 5
 if errorlevel 1 goto failed
 timeout /t 5 /nobreak >nul
 call :run reverse-p4 -R -P 4 -t 60 -O 5
 if errorlevel 1 goto failed
 goto done
)
if /i "!mode!"=="2g" (
 call :run p4 -R -P 4 -t 45
 if errorlevel 1 goto failed
 goto done
)
if /i "!mode!"=="p4" (
 call :run p4 -R -P 4 -t 90 -O 5
 if errorlevel 1 goto failed
 goto done
)
if /i "!mode!"=="tcp" (
 call :run diagnostic -R -P 4 -t 30
 if errorlevel 1 goto failed
 goto done
)
call :run p1 -R -P 1 -t 90 -O 5
if errorlevel 1 goto failed
timeout /t 10 /nobreak >nul
call :run p4 -R -P 4 -t 90 -O 5
if errorlevel 1 goto failed
timeout /t 20 /nobreak >nul
call :run wake -R -P 4 -t 30
if errorlevel 1 goto failed
:done
set "result=complete"
set "rc=0"
goto finish
:failed
set "result=failed; keep router and client evidence before restart"
set "rc=1"
:finish
if /i "!mode!"=="wired" call :wired_metadata client-after
netsh wlan show interfaces >"!output!\link-after.txt" 2>&1
netstat -s -p tcp >"!output!\tcp-after.txt" 2>&1
>>"!output!\manifest.txt" echo end_local=!DATE! !TIME! result=!result!
echo !result! Logs: "!output!"
exit /b !rc!
:wired_metadata
set "tag=%~1"
netsh interface show interface >"!output!\!tag!-interface.txt" 2>&1
netsh interface ipv4 show interfaces >"!output!\!tag!-ipv4-interfaces.txt" 2>&1
netsh interface ipv4 show config >"!output!\!tag!-ipv4-config.txt" 2>&1
netsh interface ipv4 show subinterfaces >"!output!\!tag!-ipv4-subinterfaces.txt" 2>&1
netsh interface ipv4 show tcpstats >"!output!\!tag!-ipv4-tcpstats.txt" 2>&1
netsh interface tcp show global >"!output!\!tag!-tcp-global.txt" 2>&1
netsh interface tcp show heuristics >"!output!\!tag!-tcp-heuristics.txt" 2>&1
netsh interface tcp show supplemental >"!output!\!tag!-tcp-supplemental.txt" 2>&1
set "class=HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
rem Read only instance values; excludes huge Ndi parameter-description subtrees.
>"!output!\!tag!-nic-registry.txt" (
 for /f "delims=" %%K in ('reg query "!class!" 2^>nul ^| findstr /r "\\[0-9][0-9][0-9][0-9]$"') do reg query "%%K" 2>&1
)
>"!output!\!tag!-tcp-registry.txt" (
 reg query "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" 2>&1
 reg query "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" /s 2>&1
)
exit /b 0
:run
set "tag=%~1"
set "args=%2 %3 %4 %5 %6 %7 %8 %9"
>"!output!\!tag!.txt" (
 echo !DATE! !TIME!
 echo command="!iperf!" -c !server! -p 5201 !args! -i 1 --get-server-output !limits!
)
call :mark begin-!mode!-!tag!
if errorlevel 1 exit /b 2
echo Running !mode! !tag! against !server! ...
"!iperf!" -c !server! -p 5201 !args! -i 1 --get-server-output !limits! >>"!output!\!tag!.txt" 2>&1
set "test_rc=!errorlevel!"
>>"!output!\!tag!.txt" echo end_local=!DATE! !TIME! exit_code=!test_rc!
call :mark end-!mode!-!tag!-rc!test_rc!
if errorlevel 1 exit /b 2
exit /b !test_rc!
:mark
if not defined CLANKER_ROUTER exit /b 0
>>"!output!\router-markers.txt" echo local=!DATE! !TIME! label=%~1
call :router_mark %~1 >>"!output!\router-markers.txt" 2>&1
set "mark_rc=!errorlevel!"
if not "!mark_rc!"=="0" (
 type "!output!\router-markers.txt"
 echo ERROR: Router marker failed. Keep these logs and the active router record.
)
exit /b !mark_rc!
:router_preflight
>"!output!\router-preflight.txt" echo client_fix=r76-ssh3 target=!CLANKER_ROUTER! recorder_dir=!CLANKER_ROUTER_DIR!
ssh -n -x -o ForwardX11=no -o RequestTTY=no -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 root@!CLANKER_ROUTER! "echo CLANKER_SSH_OK; cat /proc/uptime" >>"!output!\router-preflight.txt" 2>&1
set "ssh_rc=!errorlevel!"
>>"!output!\router-preflight.txt" echo ssh_connect_exit=!ssh_rc!
if not "!ssh_rc!"=="0" (
 type "!output!\router-preflight.txt"
 echo ERROR: SSH command execution failed. See ssh_connect_exit above.
 exit /b 2
)
rem Trust the captured SSH exit code; SSH stdout may use Unix LF endings.
rem Do not use FINDSTR /X on the mixed Windows/SSH diagnostic log.
call :router_mark client-preflight >>"!output!\router-preflight.txt" 2>&1
set "preflight_rc=!errorlevel!"
if not "!preflight_rc!"=="0" (
 type "!output!\router-preflight.txt"
 echo ERROR: SSH login succeeded; recorder marker failed. See the specific reason above.
 echo Start the router recorder first and use exactly the same directory in CLANKER_ROUTER_DIR.
 exit /b 2
)
exit /b 0
:router_mark
rem Validated path and fixed labels contain no shell metacharacters.
rem Diagnose the installed r76 --mark even when its failure is silent.
ssh -n -x -o ForwardX11=no -o RequestTTY=no -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 root@!CLANKER_ROUTER! "echo remote_stage=mark directory='!CLANKER_ROUTER_DIR!' label='%~1'; if command -v airoha-clanker-offload; then :; else echo ERROR: recorder_command_missing; exit 24; fi; if test -d '!CLANKER_ROUTER_DIR!'; then :; else echo ERROR: recorder_directory_missing; exit 20; fi; if test -r '!CLANKER_ROUTER_DIR!/manifest.txt'; then :; else echo ERROR: recorder_manifest_missing; exit 21; fi; if test -e '!CLANKER_ROUTER_DIR!/finish.log'; then echo ERROR: recorder_finished_start_a_new_record; exit 22; fi; if test -e '!CLANKER_ROUTER_DIR!/stop.request'; then echo ERROR: recorder_stop_requested; exit 23; fi; airoha-clanker-offload --mark '!CLANKER_ROUTER_DIR!' '%~1'; rc=$?; echo remote_mark_exit=$rc; if test $rc -eq 0; then echo CLANKER_MARK_OK; else echo ERROR: marker_write_failed; fi; exit $rc"
set "ssh_mark_rc=!errorlevel!"
echo ssh_marker_exit=!ssh_mark_rc!
exit /b !ssh_mark_rc!
:usage
echo Usage: %~nx0 5g^|2g^|tcp^|wired^|p4 SERVER_IPV4 NEW_LOG_DIR [PATH_TO_IPERF3.EXE] [wan^|lan]
echo 5g: P1 90s / P4 90s / idle-wake P4 30s. 2g: P4 45s.
echo wired: both directions P1/P4 60s each; LAN1 stays WAN.
echo tcp: separate 30s diagnostic with endpoint capture; not a throughput baseline.
echo Select the Wi-Fi band in Windows before each invocation. Use the same PC.
exit /b 2
