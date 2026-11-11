@echo off
:: ============================================================================
:: retrim-admin.bat - full-volume Retrim + weekly auto Retrim for a Windows
::                    guest whose disk lives on a KVM host (qcow2).
::
:: HOW TO RUN: right-click this file -> "Run as administrator"
::             (or execute from an already-elevated CMD / PowerShell)
::
:: Prerequisite: host-side fix already applied, i.e. libvirt XML has
::   <driver name='qemu' type='qcow2' discard='unmap'/> and bus='scsi'
::   (VirtIO SCSI), followed by a COLD BOOT. Without that, defrag /L
::   returns success but the host silently drops every TRIM.
::
:: The first Retrim may take 10-40 minutes on a large volume.
:: Keep this window open until it finishes.
:: ============================================================================
setlocal
set "LOG=%~dp0retrim-admin.log"

whoami /groups | find "S-1-16-12288" >nul 2>&1
if errorlevel 1 (
  echo.
  echo  [ERROR] This window is NOT elevated ^(Medium integrity^).
  echo  Right-click this .bat ^> "Run as administrator".
  echo.
  pause
  exit /b 1
)

echo [%date% %time%] START elevated > "%LOG%"
echo ==========================================================
echo   VM disk reclaim - full-volume Retrim + weekly auto Retrim
echo   Elevation check: OK ^(High Mandatory Level^)
echo ==========================================================
echo.

echo  [1/3] Full-volume Retrim on C:
echo        KEEP THIS WINDOW OPEN. May take 10-40 minutes.
echo.
defrag.exe /L C:
set "RC1=%ERRORLEVEL%"
echo [%date% %time%] defrag_exit=%RC1% >> "%LOG%"
echo        defrag exit code = %RC1%
echo.

echo  [2/3] Register weekly SYSTEM task ^(Sunday 03:00^) ...
schtasks /Create /TN "VM-AutoRetrim" /TR "C:\Windows\System32\defrag.exe /L C:" /SC WEEKLY /D SUN /ST 03:00 /RU SYSTEM /RL HIGHEST /F
set "RC2=%ERRORLEVEL%"
echo [%date% %time%] schtasks_exit=%RC2% >> "%LOG%"
echo        schtasks exit code = %RC2%
echo.

echo  [3/3] Verify task ...
schtasks /Query /TN "VM-AutoRetrim" /FO LIST
schtasks /Query /TN "VM-AutoRetrim" /FO LIST >> "%LOG%" 2>&1
echo [%date% %time%] DONE >> "%LOG%"
echo.
echo ==========================================================
echo   Finished. Log: %LOG%
echo.
echo   Next - verify on the HOST side:
echo     qemu-img info --force-share <disk>.qcow2   (disk size should
echo     now be close to the guest's real data usage), and
echo     df -h <pool>   (pool free space should have recovered).
echo ==========================================================
echo.
echo  Press any key to close this window.
pause >nul
endlocal
exit /b 0
