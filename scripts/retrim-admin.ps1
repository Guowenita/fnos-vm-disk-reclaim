# ============================================================================
# retrim-admin.ps1 - full-volume Retrim + weekly auto Retrim for a Windows
#                    guest whose disk lives on a KVM host (qcow2).
#
# HOW TO RUN: from an elevated PowerShell:
#   powershell -NoProfile -ExecutionPolicy Bypass -File retrim-admin.ps1
#
# Prerequisite: host-side fix applied first (libvirt XML
#   <driver ... discard='unmap'/> + VirtIO SCSI bus + COLD BOOT).
#
# Notes from field testing:
#   - Windows' built-in ScheduledDefrag action is 'defrag -c -h -o -'
#     WITHOUT /L - it never issues TRIM. That is why a dedicated weekly
#     task with /L is needed.
#   - defrag.exe inside a Session-0 SYSTEM background job was observed
#     to idle forever (zero CPU, zero reads). The FIRST full-volume
#     Retrim must run in an interactive elevated window (as here).
#     The weekly SYSTEM task is a best-effort backstop - verify it
#     actually ran via 'schtasks /Query' LastResult.
# ============================================================================

$log = Join-Path $PSScriptRoot 'retrim-admin.log'
$o = @()
$o += 'Time=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$o += 'IsAdmin=' + $isAdmin
if (-not $isAdmin) {
    $o += 'FATAL=not elevated, abort. Run from an elevated PowerShell.'
    $o | Out-File -FilePath $log -Encoding utf8
    Write-Host 'FATAL: run from an elevated PowerShell.' -ForegroundColor Red
    exit 1
}

$o += 'DeleteNotify=' + ((fsutil behavior query DisableDeleteNotify) -join ' | ')
$o += '=== disk identity (expect VirtIO SCSI after the host-side fix) ==='
Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
    $o += 'PD=' + $_.FriendlyName + ' Media=' + $_.MediaType + ' Bus=' + $_.BusType
    Write-Host ('PD: ' + $_.FriendlyName + ' / ' + $_.MediaType + ' / ' + $_.BusType)
}
try {
    $o += 'vioscsi_Start=' + (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\vioscsi' -ErrorAction Stop).Start
} catch {
    $o += 'vioscsi=not installed (only relevant for VirtIO SCSI disks)'
}

Write-Host ''
Write-Host '[1/3] Full-volume Retrim on C: (10-40 min, keep this window open)' -ForegroundColor Cyan
$o += '=== [1] full-volume Retrim ==='
try {
    Optimize-Volume -DriveLetter C -ReTrim -Verbose -ErrorAction Stop 4>&1 | ForEach-Object {
        $o += 'OPT=' + ($_ | Out-String).Trim()
    }
    $o += 'OptimizeVolume=OK'
} catch {
    $o += 'OptimizeVolume_ERR=' + $_.Exception.Message
}
try {
    $r = & "$env:SystemRoot\System32\defrag.exe" /L C: 2>&1
    $o += ($r | Out-String)
    $o += 'DefragExitCode=' + $LASTEXITCODE
} catch {
    $o += 'Defrag_ERR=' + $_.Exception.Message
}

Write-Host ''
Write-Host '[2/3] Register weekly SYSTEM auto Retrim (Sunday 03:00)' -ForegroundColor Cyan
$o += '=== [2] weekly task ==='
try {
    $act = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\defrag.exe" -Argument '/L C:'
    $trg = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 03:00
    $prn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'VM-AutoRetrim' -Action $act -Trigger $trg -Principal $prn `
        -Description 'Weekly full-volume Retrim: return freed NTFS clusters to the host qcow2' `
        -Force -ErrorAction Stop | Out-Null
    $o += 'AutoRetrimTask=OK'
} catch {
    $o += 'AutoRetrimTask_ERR=' + $_.Exception.Message
}

Write-Host ''
Write-Host '[3/3] Verify' -ForegroundColor Cyan
try {
    $t = Get-ScheduledTask -TaskName 'VM-AutoRetrim' -ErrorAction Stop
    $i = Get-ScheduledTaskInfo -TaskName 'VM-AutoRetrim' -ErrorAction Stop
    $o += 'TaskState=' + $t.State + ' NextRun=' + $i.NextRunTime
    Write-Host ('Task: ' + $t.State + '  NextRun: ' + $i.NextRunTime)
    foreach ($a in $t.Actions) { $o += 'TaskAction=' + $a.Execute + ' ' + $a.Arguments }
} catch {
    $o += 'TaskVerify_ERR=' + $_.Exception.Message
}

$o += 'Done=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
$o | Out-File -FilePath $log -Encoding utf8
Write-Host ''
Write-Host ('Log: ' + $log)
Write-Host 'Now verify host-side: qemu-img info disk size should be close to guest usage.'
