param(
    [Parameter(Mandatory = $true, HelpMessage = "Root directory containing subfolders like transmit, responses, upload_responses, completed.")]
    [string]$RootDir,

    [Parameter(Mandatory = $false)] [string]$TransmitDir = "transmit",
    [Parameter(Mandatory = $false)] [string]$ResponseDir = "responses",
    [Parameter(Mandatory = $false)] [string]$UploadResponseDir = "responses",
    [Parameter(Mandatory = $false)] [string]$CompletedDir = "completed",
    [Parameter(Mandatory = $false)] [string]$LogDir = "logs",

    # Choose which timestamp to use for ordering
    [Parameter(Mandatory = $false)] [ValidateSet('CreationTime','LastWriteTime')] [string]$OrderByTimeField = 'CreationTime',

    # Suffix patterns to distinguish types (wildcards supported)
    [Parameter(Mandatory = $false)] [string]$ConfirmationSuffixFilter = '*.030001.x12',
    [Parameter(Mandatory = $false)] [string]$ResultSuffixFilter = '*.100001.x12',

    # External commands to run for upload and download (e.g., paths to .bat files). Optional.
    [Parameter(Mandatory = $false)] [string]$UploadCommand = "",
    [Parameter(Mandatory = $false)] [string]$DownloadCommand = "",

    # Optional command to run after a successful download (e.g., your CSV copy step)
    [Parameter(Mandatory = $false)] [string]$PostDownloadCommand = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-DirectoryIfMissing {
    param(
        [Parameter(Mandatory = $true)] [string]$PathToEnsure
    )
    if (-not (Test-Path -Path $PathToEnsure)) {
        [void](New-Item -Path $PathToEnsure -ItemType Directory -Force)
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)] [string]$Message,
        [Parameter(Mandatory = $false)] [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')] [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp][$Level] $Message"
    Write-Host $line
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line
    }
}

function Invoke-ExternalCommandViaCmd {
    [CmdletBinding()] param(
        [Parameter(Mandatory = $true)] [string]$CommandLine
    )
    Write-Log -Message "Executing: $CommandLine" -Level 'DEBUG'
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $CommandLine) -Wait -PassThru -WindowStyle Hidden
    return ($proc.ExitCode -eq 0)
}

function Get-LatestFileMatching {
    [CmdletBinding()] param(
        [Parameter(Mandatory = $true)] [string]$DirectoryPath,
        [Parameter(Mandatory = $true)] [string]$Filter,
        [Parameter(Mandatory = $false)] [ValidateSet('CreationTime','LastWriteTime')] [string]$TimeField = 'CreationTime'
    )
    if (-not (Test-Path -Path $DirectoryPath)) { return $null }
    $files = Get-ChildItem -Path $DirectoryPath -File -Filter $Filter -ErrorAction SilentlyContinue
    if (-not $files) { return $null }
    if ($TimeField -eq 'LastWriteTime') {
        return ($files | Sort-Object -Property LastWriteTime, Name | Select-Object -Last 1)
    }
    else {
        return ($files | Sort-Object -Property CreationTime, Name | Select-Object -Last 1)
    }
}

function Get-FileTimeValue {
    param(
        [Parameter(Mandatory = $true)] [System.IO.FileInfo]$FileInfo,
        [Parameter(Mandatory = $true)] [ValidateSet('CreationTime','LastWriteTime')] [string]$TimeField
    )
    if ($null -eq $FileInfo) { return $null }
    if ($TimeField -eq 'LastWriteTime') { return $FileInfo.LastWriteTime }
    return $FileInfo.CreationTime
}

function Invoke-EligibilityUpload {
    [CmdletBinding()] param(
        [Parameter(Mandatory = $true)] [string]$TransmitPath,
        [Parameter(Mandatory = $true)] [string]$UploadResponsePath,
        [Parameter(Mandatory = $false)] [string]$CommandLine
    )
    try {
        if (-not [string]::IsNullOrWhiteSpace($CommandLine)) {
            Write-Log -Message "Running upload command."
            $ok = Invoke-ExternalCommandViaCmd -CommandLine $CommandLine
            return $ok
        }
        else {
            Write-Log -Message "No UploadCommand provided. Skipping upload step." -Level 'WARN'
            return $true
        }
    }
    catch {
        Write-Log -Message ("Upload failed: " + $_.Exception.Message) -Level 'ERROR'
        return $false
    }
}

function Invoke-EligibilityDownload {
    [CmdletBinding()] param(
        [Parameter(Mandatory = $true)] [string]$TransmitPath,
        [Parameter(Mandatory = $true)] [string]$ResponsePath,
        [Parameter(Mandatory = $false)] [string]$CommandLine
    )
    try {
        if (-not [string]::IsNullOrWhiteSpace($CommandLine)) {
            Write-Log -Message "Running download command."
            $ok = Invoke-ExternalCommandViaCmd -CommandLine $CommandLine
            return $ok
        }
        else {
            Write-Log -Message "No DownloadCommand provided. Skipping download step." -Level 'WARN'
            return $false
        }
    }
    catch {
        Write-Log -Message ("Download failed: " + $_.Exception.Message) -Level 'ERROR'
        return $false
    }
}

function Move-OldFilesToCompleted {
    [CmdletBinding()] param(
        [Parameter(Mandatory = $true)] [string]$TransmitPath,
        [Parameter(Mandatory = $true)] [string]$ResponsePath,
        [Parameter(Mandatory = $true)] [string]$CompletedPath,
        [Parameter(Mandatory = $true)] [System.Collections.Generic.HashSet[string]]$KeepFullPaths
    )

    $archiveRoot = Join-Path $CompletedPath (Get-Date -Format 'yyyyMMdd_HHmmss')
    $archiveTransmit = Join-Path $archiveRoot 'transmit'
    $archiveResponse = Join-Path $archiveRoot 'responses'

    Initialize-DirectoryIfMissing -PathToEnsure $archiveTransmit
    Initialize-DirectoryIfMissing -PathToEnsure $archiveResponse

    $movedCount = 0

    if (Test-Path -Path $TransmitPath) {
        $toArchiveTx = Get-ChildItem -Path $TransmitPath -File -ErrorAction SilentlyContinue
        foreach ($file in $toArchiveTx) {
            if (-not $KeepFullPaths.Contains($file.FullName)) {
                $dest = Join-Path $archiveTransmit $file.Name
                Move-Item -Path $file.FullName -Destination $dest -Force
                $movedCount++
            }
        }
    }

    if (Test-Path -Path $ResponsePath) {
        $toArchiveResp = Get-ChildItem -Path $ResponsePath -File -ErrorAction SilentlyContinue
        foreach ($file in $toArchiveResp) {
            if (-not $KeepFullPaths.Contains($file.FullName)) {
                $dest = Join-Path $archiveResponse $file.Name
                Move-Item -Path $file.FullName -Destination $dest -Force
                $movedCount++
            }
        }
    }

    Write-Log -Message "Archived $movedCount file(s) to $archiveRoot (keeping latest transmit/confirm/result)."
}

# Resolve and ensure directories
$ResolvedTransmitDir = if ([System.IO.Path]::IsPathRooted($TransmitDir)) { $TransmitDir } else { Join-Path $RootDir $TransmitDir }
$ResolvedResponseDir = if ([System.IO.Path]::IsPathRooted($ResponseDir)) { $ResponseDir } else { Join-Path $RootDir $ResponseDir }
$ResolvedUploadRespDir = if ([System.IO.Path]::IsPathRooted($UploadResponseDir)) { $UploadResponseDir } else { Join-Path $RootDir $UploadResponseDir }
$ResolvedCompletedDir = if ([System.IO.Path]::IsPathRooted($CompletedDir)) { $CompletedDir } else { Join-Path $RootDir $CompletedDir }
$ResolvedLogDir = if ([System.IO.Path]::IsPathRooted($LogDir)) { $LogDir } else { Join-Path $RootDir $LogDir }

Initialize-DirectoryIfMissing -PathToEnsure $ResolvedTransmitDir
Initialize-DirectoryIfMissing -PathToEnsure $ResolvedResponseDir
Initialize-DirectoryIfMissing -PathToEnsure $ResolvedUploadRespDir
Initialize-DirectoryIfMissing -PathToEnsure $ResolvedCompletedDir
Initialize-DirectoryIfMissing -PathToEnsure $ResolvedLogDir

# Prepare logging
$script:LogFile = Join-Path $ResolvedLogDir ("eligibility_" + (Get-Date -Format 'yyyyMMdd') + ".log")
Write-Log -Message "Starting eligibility run. Root: $RootDir"
Write-Log -Message "Time field for ordering: $OrderByTimeField; Confirm filter: $ConfirmationSuffixFilter; Result filter: $ResultSuffixFilter" -Level 'DEBUG'

# Discover latest confirmation and result
$latestConfirm = Get-LatestFileMatching -DirectoryPath $ResolvedResponseDir -Filter $ConfirmationSuffixFilter -TimeField $OrderByTimeField
$latestResult = Get-LatestFileMatching -DirectoryPath $ResolvedResponseDir -Filter $ResultSuffixFilter -TimeField $OrderByTimeField

$latestConfirmTime = Get-FileTimeValue -FileInfo $latestConfirm -TimeField $OrderByTimeField
$latestResultTime = Get-FileTimeValue -FileInfo $latestResult -TimeField $OrderByTimeField

Write-Log -Message ("Latest confirm: " + ($latestConfirm?.Name ?? '<none>') + " @ " + ($latestConfirmTime?.ToString('yyyy-MM-dd HH:mm:ss') ?? 'n/a')) -Level 'DEBUG'
Write-Log -Message ("Latest result:  " + ($latestResult?.Name ?? '<none>') + " @ " + ($latestResultTime?.ToString('yyyy-MM-dd HH:mm:ss') ?? 'n/a')) -Level 'DEBUG'

# Determine actions
$hasTransmissionFile = $false
if (Test-Path -Path $ResolvedTransmitDir) {
    $hasTransmissionFile = [bool](Get-ChildItem -Path $ResolvedTransmitDir -File -ErrorAction SilentlyContinue | Select-Object -First 1)
}

# Upload gating: if the latest thing is a confirmation newer than any result, we're waiting; skip upload
$waitingForResult = $false
if ($latestConfirmTime -ne $null -and ($latestResultTime -eq $null -or $latestConfirmTime -ge $latestResultTime)) {
    $waitingForResult = $true
}

if ($waitingForResult) {
    Write-Log -Message "Latest confirmation is newer than any result. Waiting for results; skipping upload."
}
else {
    if ($hasTransmissionFile) {
        Write-Log -Message "No pending confirmation without result. Upload is allowed; attempting upload..."
        $uploadOk = Invoke-EligibilityUpload -TransmitPath $ResolvedTransmitDir -UploadResponsePath $ResolvedUploadRespDir -CommandLine $UploadCommand
        if ($uploadOk) { Write-Log -Message "Upload step completed successfully." }
        else { Write-Log -Message "Upload step failed." -Level 'WARN' }
    }
    else {
        Write-Log -Message "No transmission file exists. Skipping upload."
    }
}

# Download gating: if we already have a result that is at least as new as confirmation, skip download
$shouldSkipDownload = $false
if ($latestResultTime -ne $null -and ($latestConfirmTime -eq $null -or $latestResultTime -ge $latestConfirmTime)) {
    $shouldSkipDownload = $true
}

$downloadSucceeded = $false
if ($shouldSkipDownload) {
    Write-Log -Message "Latest result is present and not older than confirmation. Skipping download."
}
else {
    if ($hasTransmissionFile) {
        Write-Log -Message "No latest result for the latest confirmation. Attempting download..."
        $downloadSucceeded = Invoke-EligibilityDownload -TransmitPath $ResolvedTransmitDir -ResponsePath $ResolvedResponseDir -CommandLine $DownloadCommand
        if ($downloadSucceeded) {
            Write-Log -Message "Download step completed successfully."
            if (-not [string]::IsNullOrWhiteSpace($PostDownloadCommand)) {
                Write-Log -Message "Running post-download command..."
                $postOk = Invoke-ExternalCommandViaCmd -CommandLine $PostDownloadCommand
                if ($postOk) { Write-Log -Message "Post-download command completed successfully." }
                else { Write-Log -Message "Post-download command failed." -Level 'WARN' }
            }
        }
        else {
            Write-Log -Message "Download step failed." -Level 'WARN'
        }
    }
    else {
        Write-Log -Message "No transmission file exists. Skipping download."
    }
}

# Archival: after a successful download, archive everything except the latest confirm, latest result, and newest transmit file
if ($downloadSucceeded) {
    try {
        $keep = New-Object 'System.Collections.Generic.HashSet[string]'
        $newestTransmit = Get-LatestFileMatching -DirectoryPath $ResolvedTransmitDir -Filter '*' -TimeField $OrderByTimeField
        if ($newestTransmit) { $null = $keep.Add($newestTransmit.FullName) }
        if ($latestConfirm) { $null = $keep.Add($latestConfirm.FullName) }
        if ($latestResult) { $null = $keep.Add($latestResult.FullName) }
        Move-OldFilesToCompleted -TransmitPath $ResolvedTransmitDir -ResponsePath $ResolvedResponseDir -CompletedPath $ResolvedCompletedDir -KeepFullPaths $keep
    }
    catch {
        Write-Log -Message ("Archival failed: " + $_.Exception.Message) -Level 'ERROR'
        exit 1
    }
}

Write-Log -Message "Eligibility run complete."