#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$MountPath = 'C:\mountYellowkeyFix',
    [string]$HiveName = 'WinREHive',
    [string]$LogDirectory = 'C:\ProgramData\YellowKey-Mitigation'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------
# Helper functions
# -----------------------------
function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string[]]$ArgumentList = @()
    )

    $output = & $FilePath @ArgumentList 2>&1 | ForEach-Object { $_.ToString() }
    $exitCode = $LASTEXITCODE

    [pscustomobject]@{
        FilePath  = $FilePath
        Arguments = ($ArgumentList -join ' ')
        ExitCode  = $exitCode
        Output    = ($output -join [Environment]::NewLine).Trim()
    }
}

function Get-TimePair {
    [pscustomobject]@{
        Local = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")
        UTC   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'")
    }
}

$Summary = New-Object System.Collections.Generic.List[object]

function Add-SummaryStep {
    param(
        [int]$StepNumber,
        [string]$StepName,
        [ValidateSet('Success','Failed','Skipped','NoChange')]
        [string]$Status,
        [string]$Details,
        [bool]$Changed = $false
    )

    $t = Get-TimePair
    $Summary.Add([pscustomobject]@{
        Step       = $StepNumber
        StepName   = $StepName
        Status     = $Status
        Changed    = $Changed
        LocalTime  = $t.Local
        UTCTime    = $t.UTC
        Details    = $Details
    })
}

function Save-Summary {
    param(
        [string]$DirectoryPath
    )

    if (-not (Test-Path -LiteralPath $DirectoryPath)) {
        New-Item -Path $DirectoryPath -ItemType Directory -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $DirectoryPath "YellowKey-WinRE-Mitigation-$stamp.json"
    $txtPath  = Join-Path $DirectoryPath "YellowKey-WinRE-Mitigation-$stamp.txt"

    $Summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $text = $Summary | Format-Table -AutoSize | Out-String
    Set-Content -LiteralPath $txtPath -Value $text -Encoding UTF8

    [pscustomobject]@{
        JsonPath = $jsonPath
        TextPath = $txtPath
    }
}

function Get-ReAgentStatus {
    $result = Invoke-ExternalCommand -FilePath 'reagentc.exe' -ArgumentList @('/info')
    if ($result.ExitCode -ne 0) {
        throw "reagentc /info failed. ExitCode=$($result.ExitCode). Output: $($result.Output)"
    }

    $enabled = $null
    if ($result.Output -match 'Windows RE status:\s+Enabled') { $enabled = $true }
    elseif ($result.Output -match 'Windows RE status:\s+Disabled') { $enabled = $false }

    [pscustomobject]@{
        Enabled = $enabled
        Raw     = $result.Output
    }
}

function Ensure-EmptyMountDirectory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        return
    }

    $children = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($children) {
        throw "Mount path '$Path' already exists and is not empty. Refusing to proceed."
    }
}

function Unload-HiveIfLoaded {
    param([string]$HiveName)

    $regPath = "Registry::HKEY_LOCAL_MACHINE\$HiveName"
    if (Test-Path -LiteralPath $regPath) {
        $res = Invoke-ExternalCommand -FilePath 'reg.exe' -ArgumentList @('unload', "HKLM\$HiveName")
        return $res
    }

    return $null
}

function Unmount-WinREBestEffort {
    param(
        [string]$MountPath,
        [switch]$Commit
    )

    $args = @('/unmountre', '/path', $MountPath)
    if ($Commit) {
        $args += '/commit'
    }
    else {
        $args += '/discard'
    }

    $res = Invoke-ExternalCommand -FilePath 'reagentc.exe' -ArgumentList $args
    return $res
}

# -----------------------------
# Preconditions
# -----------------------------
if (-not (Test-IsAdministrator)) {
    throw "This script must run elevated (Run as Administrator)."
}

$hiveRoot = "Registry::HKEY_LOCAL_MACHINE\$HiveName"
$hiveFile = Join-Path $MountPath 'Windows\System32\config\SYSTEM'

$step1Succeeded = $false
$step2Succeeded = $false
$step3Succeeded = $false
$step4Succeeded = $false
$step5Succeeded = $false
$changeRequired = $false
$changeApplied  = $false
$mounted        = $false
$hiveLoaded     = $false

# -----------------------------
# Main execution
# -----------------------------
try {
    # Optional pre-check
    $preInfo = Get-ReAgentStatus
    if ($preInfo.Enabled -ne $true) {
        throw "Windows RE is not enabled before start. Current state: $($preInfo.Raw)"
    }

    # Step 1: Mount the WinRE image
    Ensure-EmptyMountDirectory -Path $MountPath
    $res1 = Invoke-ExternalCommand -FilePath 'reagentc.exe' -ArgumentList @('/mountre', '/path', $MountPath)
    if ($res1.ExitCode -ne 0) {
        throw "Step 1 failed. ExitCode=$($res1.ExitCode). Output: $($res1.Output)"
    }

    if (-not (Test-Path -LiteralPath $hiveFile)) {
        throw "Step 1 verification failed. Expected hive file not found: $hiveFile"
    }

    $step1Succeeded = $true
    $mounted = $true
    Add-SummaryStep -StepNumber 1 -StepName 'Mount WinRE image' -Status 'Success' -Details "Mounted to '$MountPath'."

    # Step 2: Load the mounted SYSTEM hive
    $res2 = Invoke-ExternalCommand -FilePath 'reg.exe' -ArgumentList @('load', "HKLM\$HiveName", $hiveFile)
    if ($res2.ExitCode -ne 0) {
        throw "Step 2 failed. ExitCode=$($res2.ExitCode). Output: $($res2.Output)"
    }

    if (-not (Test-Path -LiteralPath $hiveRoot)) {
        throw "Step 2 verification failed. Offline hive not present at HKLM\$HiveName."
    }

    $step2Succeeded = $true
    $hiveLoaded = $true
    Add-SummaryStep -StepNumber 2 -StepName 'Load offline WinRE SYSTEM hive' -Status 'Success' -Details "Loaded hive HKLM\$HiveName."

    # Step 3: Remove autofstx.exe from BootExecute (all detected ControlSet###)
    $controlSets = Get-ChildItem -Path $hiveRoot -ErrorAction Stop |
        Where-Object { $_.PSChildName -match '^ControlSet\d{3}$' } |
        Select-Object -ExpandProperty PSChildName

    if (-not $controlSets) {
        throw "Step 3 failed. No ControlSet### keys found in HKLM\$HiveName."
    }

    $modifiedSets = @()
    $inspectedSets = @()
    $bootExecuteMissing = @()

    foreach ($cs in $controlSets) {
        $smPath = "Registry::HKEY_LOCAL_MACHINE\$HiveName\$cs\Control\Session Manager"
        $inspectedSets += $cs

        try {
            $currentValue = (Get-ItemProperty -Path $smPath -Name 'BootExecute' -ErrorAction Stop).BootExecute
        }
        catch {
            $bootExecuteMissing += $cs
            continue
        }

        # Normalize to string array
        if ($currentValue -isnot [System.Array]) {
            $currentValue = @([string]$currentValue)
        }

        $containsTarget = $false
        foreach ($entry in $currentValue) {
            if ($null -ne $entry -and $entry.Trim().ToLowerInvariant() -eq 'autofstx.exe') {
                $containsTarget = $true
                break
            }
        }

        if ($containsTarget) {
            $changeRequired = $true
            $newValue = @(
                foreach ($entry in $currentValue) {
                    if ($null -eq $entry) { continue }
                    if ($entry.Trim().ToLowerInvariant() -ne 'autofstx.exe') {
                        $entry
                    }
                }
            )

            # Write back REG_MULTI_SZ
            Set-ItemProperty -Path $smPath -Name 'BootExecute' -Value $newValue -Type MultiString -ErrorAction Stop

            # Verify write
            $verifyValue = (Get-ItemProperty -Path $smPath -Name 'BootExecute' -ErrorAction Stop).BootExecute
            if ($verifyValue -isnot [System.Array]) {
                $verifyValue = @([string]$verifyValue)
            }

            $stillPresent = $false
            foreach ($entry in $verifyValue) {
                if ($null -ne $entry -and $entry.Trim().ToLowerInvariant() -eq 'autofstx.exe') {
                    $stillPresent = $true
                    break
                }
            }

            if ($stillPresent) {
                throw "Step 3 verification failed for $cs. 'autofstx.exe' is still present in BootExecute."
            }

            $modifiedSets += $cs
        }
    }

    if ($changeRequired -and $modifiedSets.Count -gt 0) {
        $changeApplied = $true
        $step3Succeeded = $true
        Add-SummaryStep -StepNumber 3 -StepName 'Remove autofstx.exe from BootExecute' -Status 'Success' -Changed $true -Details (
            "Modified BootExecute in: {0}. Inspected: {1}. Missing BootExecute in: {2}." -f `
            ($modifiedSets -join ', '), `
            ($inspectedSets -join ', '), `
            ($(if ($bootExecuteMissing) { $bootExecuteMissing -join ', ' } else { 'None' }))
        )
    }
    elseif (-not $changeRequired) {
        $step3Succeeded = $true
        Add-SummaryStep -StepNumber 3 -StepName 'Remove autofstx.exe from BootExecute' -Status 'NoChange' -Changed $false -Details (
            "No 'autofstx.exe' entry found in any detected ControlSet BootExecute value. Inspected: {0}. Missing BootExecute in: {1}." -f `
            ($inspectedSets -join ', '), `
            ($(if ($bootExecuteMissing) { $bootExecuteMissing -join ', ' } else { 'None' }))
        )
    }
    else {
        throw "Step 3 failed. A change appeared necessary but no ControlSet was successfully updated."
    }

    # Step 4: Unload the hive
    $res4 = Invoke-ExternalCommand -FilePath 'reg.exe' -ArgumentList @('unload', "HKLM\$HiveName")
    if ($res4.ExitCode -ne 0) {
        throw "Step 4 failed. ExitCode=$($res4.ExitCode). Output: $($res4.Output)"
    }

    if (Test-Path -LiteralPath $hiveRoot) {
        throw "Step 4 verification failed. HKLM\$HiveName is still loaded."
    }

    $hiveLoaded = $false
    $step4Succeeded = $true
    Add-SummaryStep -StepNumber 4 -StepName 'Unload offline hive' -Status 'Success' -Details "Unloaded HKLM\$HiveName."

    # Step 5: Unmount WinRE image
    if ($changeApplied) {
        $res5 = Invoke-ExternalCommand -FilePath 'reagentc.exe' -ArgumentList @('/unmountre', '/path', $MountPath, '/commit')
        $mode = 'commit'
    }
    else {
        $res5 = Invoke-ExternalCommand -FilePath 'reagentc.exe' -ArgumentList @('/unmountre', '/path', $MountPath, '/discard')
        $mode = 'discard'
    }

    if ($res5.ExitCode -ne 0) {
        throw "Step 5 failed. ExitCode=$($res5.ExitCode). Output: $($res5.Output)"
    }

    if (Test-Path -LiteralPath (Join-Path $MountPath 'Windows')) {
        throw "Step 5 verification failed. Mount content still visible under '$MountPath'."
    }

    $mounted = $false
    $step5Succeeded = $true
    Add-SummaryStep -StepNumber 5 -StepName 'Unmount WinRE image' -Status 'Success' -Changed $changeApplied -Details "Unmounted using /$mode."

    # Step 6: Re-establish BitLocker trust only if all previous steps succeeded AND a change was actually applied
    if ($step1Succeeded -and $step2Succeeded -and $step3Succeeded -and $step4Succeeded -and $step5Succeeded -and $changeApplied) {
        $res6a = Invoke-ExternalCommand -FilePath 'reagentc.exe' -ArgumentList @('/disable')
        if ($res6a.ExitCode -ne 0) {
            throw "Step 6 (/disable) failed. ExitCode=$($res6a.ExitCode). Output: $($res6a.Output)"
        }

        $midInfo = Get-ReAgentStatus
        if ($midInfo.Enabled -ne $false) {
            throw "Step 6 verification failed after /disable. Windows RE did not report Disabled."
        }

        $res6b = Invoke-ExternalCommand -FilePath 'reagentc.exe' -ArgumentList @('/enable')
        if ($res6b.ExitCode -ne 0) {
            throw "Step 6 (/enable) failed. ExitCode=$($res6b.ExitCode). Output: $($res6b.Output)"
        }

        $postInfo = Get-ReAgentStatus
        if ($postInfo.Enabled -ne $true) {
            throw "Step 6 verification failed after /enable. Windows RE did not report Enabled."
        }

        Add-SummaryStep -StepNumber 6 -StepName 'Re-establish BitLocker trust for WinRE' -Status 'Success' -Changed $true -Details 'reagentc /disable and /enable completed successfully; WinRE status verified.'
    }
    else {
        $reason = if (-not ($step1Succeeded -and $step2Succeeded -and $step3Succeeded -and $step4Succeeded -and $step5Succeeded)) {
            'Skipped because one or more previous steps failed.'
        }
        elseif (-not $changeApplied) {
            'Skipped because no BootExecute change was required/applied.'
        }
        else {
            'Skipped due to precondition mismatch.'
        }

        Add-SummaryStep -StepNumber 6 -StepName 'Re-establish BitLocker trust for WinRE' -Status 'Skipped' -Changed $false -Details $reason
    }
}
catch {
    $err = $_.Exception.Message

    # Best-effort cleanup
    if ($hiveLoaded) {
        try {
            $cleanupHive = Unload-HiveIfLoaded -HiveName $HiveName
            if ($cleanupHive -and $cleanupHive.ExitCode -ne 0) {
                $err += " | Cleanup warning: reg unload failed with ExitCode=$($cleanupHive.ExitCode). Output: $($cleanupHive.Output)"
            }
            $hiveLoaded = $false
        }
        catch {
            $err += " | Cleanup warning: unable to unload hive: $($_.Exception.Message)"
        }
    }

    if ($mounted) {
        try {
            $cleanupUnmount = Unmount-WinREBestEffort -MountPath $MountPath
            if ($cleanupUnmount.ExitCode -ne 0) {
                $err += " | Cleanup warning: unmount/discard failed with ExitCode=$($cleanupUnmount.ExitCode). Output: $($cleanupUnmount.Output)"
            }
            $mounted = $false
        }
        catch {
            $err += " | Cleanup warning: unable to unmount WinRE: $($_.Exception.Message)"
        }
    }

    # Add failure summary for the current phase if not already obvious from prior entries
    Add-SummaryStep -StepNumber 99 -StepName 'Execution result' -Status 'Failed' -Changed $changeApplied -Details $err
}
finally {
    # Step 7: Create summary
    try {
        $paths = Save-Summary -DirectoryPath $LogDirectory
        Add-SummaryStep -StepNumber 7 -StepName 'Create summary' -Status 'Success' -Details "Saved summary to '$($paths.JsonPath)' and '$($paths.TextPath)'."
    }
    catch {
        Add-SummaryStep -StepNumber 7 -StepName 'Create summary' -Status 'Failed' -Details "Failed to save summary: $($_.Exception.Message)"
    }

    # Console output
    $Summary | Sort-Object Step | Format-Table -AutoSize
}
