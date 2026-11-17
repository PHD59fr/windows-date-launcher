# ============================================================
#                        DATE LAUNCHER
#       Run an application with a temporary system date
# ============================================================

# ############################################################
#                         CONFIGURATION
# ############################################################

# Full path to the executable.
$appPath = 'C:\Apps\MyApplication.exe'

# Temporary date (YYYY-MM-DD). The current time is preserved.
$targetDate = '2024-01-01'

# Delay before restoring the correct date (minutes).
$waitMinutes = 5

# Attempt NTP synchronization after restoring the clock,
# only if Windows Time (w32time) is already running.
$syncNtp = $true

# ############################################################
#                       IMPORTANT NOTES
# ############################################################

# Set-Date requires the "Change the system time" Windows privilege
# (SeSystemtimePrivilege). Run with adequate permissions.
#
# Windows Time (w32time, hosted by svchost.exe) may automatically
# reset the clock. Some virtual machine guest tools can also
# synchronize the clock independently of w32time.
#
# If necessary, disable automatic clock synchronization separately
# in your test environment before running this script. For example,
# in an elevated PowerShell (Windows Time only):
#   Stop-Service w32time -Force
#   Set-Service w32time -StartupType Disabled
# Re-enable Windows Time manually afterwards if needed:
#   Set-Service w32time -StartupType Manual
#   Start-Service w32time
#
# This script does NOT alter Windows services or VM settings.
# Never disable svchost.exe itself.
#
# Do not close this PowerShell process before the timer finishes:
# a forced termination may prevent clock restoration.

$ErrorActionPreference = 'Stop'

# ############################################################
#                           HELPERS
# ############################################################

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('#' * 60) -ForegroundColor Cyan
    Write-Host ('  ' + $Title) -ForegroundColor White
    Write-Host ('#' * 60) -ForegroundColor Cyan
}

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

# ############################################################
#                        INITIALIZATION
# ############################################################

Write-Section 'INITIALIZATION'

if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) {
    throw "Application not found: $appPath"
}
if ($waitMinutes -le 0) {
    throw 'waitMinutes must be greater than zero.'
}

# Parse the date strictly, before changing the system clock.
$datePart = [datetime]::ParseExact(
    $targetDate,
    'yyyy-MM-dd',
    [System.Globalization.CultureInfo]::InvariantCulture
)

$originalDate = Get-Date
$fakeDate = $datePart.Date.Add($originalDate.TimeOfDay)
$timer = [System.Diagnostics.Stopwatch]::StartNew()
$clockChanged = $false
$appStarted = $false
$failed = $false
$restorationFailed = $false

Write-Status "Application   : $appPath"
Write-Status "Original date : $originalDate"
Write-Status "Temporary date: $fakeDate"
Write-Status "Wait time     : $waitMinutes minute(s)"

try {
    # ########################################################
    #                    STEP 1 - CHANGE DATE
    # ########################################################

    Write-Section 'STEP 1/4 - CHANGE SYSTEM DATE'
    Set-Date -Date $fakeDate -ErrorAction Stop | Out-Null
    $clockChanged = $true
    Write-Status 'Temporary date applied.' 'OK'

    # ########################################################
    #                  STEP 2 - START APPLICATION
    # ########################################################

    Write-Section 'STEP 2/4 - START APPLICATION'
    Start-Process -FilePath $appPath `
        -WorkingDirectory (Split-Path -Parent $appPath) `
        -ErrorAction Stop
    $appStarted = $true
    Write-Status 'Application launched independently.' 'OK'

    # ########################################################
    #                    STEP 3 - START TIMER
    # ########################################################

    Write-Section 'STEP 3/4 - START TIMER'
    $waitSeconds = $waitMinutes * 60
    $waitTimer = [System.Diagnostics.Stopwatch]::StartNew()

    while ($waitTimer.Elapsed.TotalSeconds -lt $waitSeconds) {
        $remaining = [Math]::Max(
            0,
            [Math]::Ceiling($waitSeconds - $waitTimer.Elapsed.TotalSeconds)
        )
        $percent = [Math]::Min(
            100,
            ($waitTimer.Elapsed.TotalSeconds / $waitSeconds) * 100
        )
        Write-Progress -Activity 'Temporary system date' `
            -Status "Restoring in $remaining seconds" `
            -PercentComplete $percent
        Start-Sleep -Seconds 1
    }
    Write-Progress -Activity 'Temporary system date' -Completed
    Write-Status 'Timer completed.' 'OK'
}
catch {
    $failed = $true
    Write-Status "Execution failed: $($_.Exception.Message)" 'ERROR'
}
finally {
    # ########################################################
    #                    STEP 4 - RESTORE DATE
    # ########################################################

    if ($clockChanged) {
        Write-Section 'STEP 4/4 - RESTORE SYSTEM DATE'
        try {
            # Use a monotonic stopwatch so clock jumps do not affect
            # the amount of real time that has elapsed.
            $realDate = $originalDate.Add($timer.Elapsed)
            Set-Date -Date $realDate -ErrorAction Stop | Out-Null
            Write-Status "Clock restored: $(Get-Date)" 'OK'

            if ($syncNtp) {
                $timeService = Get-Service -Name w32time -ErrorAction SilentlyContinue
                if ($null -ne $timeService -and $timeService.Status -eq 'Running') {
                    Write-Status 'Requesting NTP synchronization...'
                    & w32tm.exe /resync /rediscover
                    if ($LASTEXITCODE -eq 0) {
                        Write-Status 'NTP synchronization requested successfully.' 'OK'
                    }
                    else {
                        Write-Status 'NTP synchronization failed; estimated time was restored.' 'WARN'
                    }
                }
                else {
                    Write-Status 'NTP skipped: Windows Time is not running.' 'WARN'
                }
            }
        }
        catch {
            $restorationFailed = $true
            Write-Status "Clock restoration failed: $($_.Exception.Message)" 'ERROR'
        }
    }

    $timer.Stop()
    Write-Section 'FINISHED'
    if ($appStarted) {
        Write-Status 'Application was launched and was not terminated by this script.' 'OK'
    }
    else {
        Write-Status 'Application was not started.' 'WARN'
    }
}

if ($failed -or $restorationFailed) {
    exit 1
}
