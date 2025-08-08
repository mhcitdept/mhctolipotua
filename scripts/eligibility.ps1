param(
    [Parameter(Mandatory = $true, HelpMessage = "Root directory containing subfolders like transmit, responses, upload_responses, completed.")]
    [string]$RootDir,

    [Parameter(Mandatory = $false)] [string]$TransmitDir = "transmit",
    [Parameter(Mandatory = $false)] [string]$ResponseDir = "responses",
    [Parameter(Mandatory = $false)] [string]$UploadResponseDir = "upload_responses",
    [Parameter(Mandatory = $false)] [string]$CompletedDir = "completed",
    [Parameter(Mandatory = $false)] [string]$LogDir = "logs",

    [Parameter(Mandatory = $false)] [string]$DateFormat = "yyyyMMdd",

    # Allows testing for a specific date (e.g., '20250104'). When empty, uses today.
    [Parameter(Mandatory = $false)] [string]$TodayOverride = "",

    # External commands to run for upload and download (e.g., paths to .bat files). Optional.
    [Parameter(Mandatory = $false)] [string]$UploadCommand = "",
    [Parameter(Mandatory = $false)] [string]$DownloadCommand = "",

    # Optional command to run after a successful download (e.g., your CSV copy step)
    [Parameter(Mandatory = $false)] [string]$PostDownloadCommand = "",

    # Detection modes for today's files: NameContainsStamp or CreatedDate
    [Parameter(Mandatory = $false)] [ValidateSet('NameContainsStamp','CreatedDate')] [string]$ResponseTodayMode = 'NameContainsStamp',
    [Parameter(Mandatory = $false)] [ValidateSet('NameContainsStamp','CreatedDate')] [string]$UploadResponseTodayMode = 'NameContainsStamp',

    # Filters when using CreatedDate mode
    [Parameter(Mandatory = $false)] [string]$ResponseExtFilter = '*.x12',
    [Parameter(Mandatory = $false)] [Nullable[long]]$ResponseMinSizeBytesForTodayMatch = $null,
    [Parameter(Mandatory = $false)] [Nullable[long]]$ResponseMaxSizeBytesForTodayMatch = $null,
    [Parameter(Mandatory = $false)] [string]$UploadResponseExtFilter = '*',
    [Parameter(Mandatory = $false)] [Nullable[long]]$UploadResponseMinSizeBytesForTodayMatch = $null,
    [Parameter(Mandatory = $false)] [Nullable[long]]$UploadResponseMaxSizeBytesForTodayMatch = $null
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

function Get-TodayStamp {
    param(
        [Parameter(Mandatory = $true)] [string]$Format,
        [Parameter(Mandatory = $false)] [string]$Override = ""
    )
    if ([string]::IsNullOrWhiteSpace($Override)) { return (Get-Date).ToString($Format) }
    return $Override
}

function Test-HasFileWithStamp {
    param(
        [Parameter(Mandatory = $true)] [string]$DirectoryPath,
        [Parameter(Mandatory = $true)] [string]$Stamp
    )
    if (-not (Test-Path -Path $DirectoryPath)) { return $false }
    $match = Get-ChildItem -Path $DirectoryPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*${Stamp}*" } |
        Select-Object -First 1
    return [bool]$match
}

function Test-HasTodayFileByCreatedDate {
    [CmdletBinding()] param(
        [Parameter(Mandatory = $true)] [string]$DirectoryPath,
        [Parameter(Mandatory = $true)] [datetime]$TodayDate,
        [Parameter(Mandatory = $false)] [string]$Filter = '*',
        [Parameter(Mandatory = $false)] [Nullable[long]]$MinSizeBytes = $null,
        [Parameter(Mandatory = $false)] [Nullable[long]]$MaxSizeBytes = $null
    )
    if (-not (Test-Path -Path $DirectoryPath)) { return $false }
    $files = Get-ChildItem -Path $DirectoryPath -File -Filter $Filter -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationTime.Date -eq $TodayDate.Date }
    if ($MinSizeBytes -ne $null) {
        $files = $files | Where-Object { $_.Length -ge $MinSizeBytes }
    }
    if ($MaxSizeBytes -ne $null) {
        $files = $files | Where-Object { $_.Length -le $MaxSizeBytes }
    }
    return [bool]($files | Select-Object -First 1)
}

function Invoke-ExternalCommandViaCmd {
    [CmdletBinding()] param(
        [Parameter(Mandatory = $true)] [string]$CommandLine
    )
    Write-Log -Message "Executing: $CommandLine" -Level 'DEBUG'
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $CommandLine) -Wait -PassThru -WindowStyle Hidden
    return ($proc.ExitCode -eq 0)
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
        [Parameter(Mandatory = $true)] [string]$TodayStamp,
        [Parameter(Mandatory = $true)] [datetime]$TodayDate
    )

    # Create a dated archive folder under completed
    $archiveRoot = Join-Path $CompletedPath (Get-Date -Format 'yyyyMMdd_HHmmss')
    $archiveTransmit = Join-Path $archiveRoot 'transmit'
    $archiveResponse = Join-Path $archiveRoot 'responses'

    Initialize-DirectoryIfMissing -PathToEnsure $archiveTransmit
    Initialize-DirectoryIfMissing -PathToEnsure $archiveResponse

    $movedCount = 0

    if (Test-Path -Path $TransmitPath) {
        $toArchiveTx = Get-ChildItem -Path $TransmitPath -File -ErrorAction SilentlyContinue |
            Where-Object { ($_.Name -notlike "*${TodayStamp}*") -and ($_.CreationTime.Date -ne $TodayDate.Date) }
        foreach ($file in $toArchiveTx) {
            $dest = Join-Path $archiveTransmit $file.Name
            Move-Item -Path $file.FullName -Destination $dest -Force
            $movedCount++
        }
    }

    if (Test-Path -Path $ResponsePath) {
        $toArchiveResp = Get-ChildItem -Path $ResponsePath -File -ErrorAction SilentlyContinue |
            Where-Object { ($_.Name -notlike "*${TodayStamp}*") -and ($_.CreationTime.Date -ne $TodayDate.Date) }
        foreach ($file in $toArchiveResp) {
            $dest = Join-Path $archiveResponse $file.Name
            Move-Item -Path $file.FullName -Destination $dest -Force
            $movedCount++
        }
    }

    Write-Log -Message "Archived $movedCount file(s) to $archiveRoot (excluding today's transmit/response)."
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

$todayStamp = Get-TodayStamp -Format $DateFormat -Override $TodayOverride
$todayDate = if ([string]::IsNullOrWhiteSpace($TodayOverride)) { Get-Date } else { [datetime]::ParseExact($TodayOverride, $DateFormat, $null) }
Write-Log -Message "Using date stamp: $todayStamp; date: $($todayDate.ToString('yyyy-MM-dd'))" -Level 'DEBUG'

# 1) If we have a submission response for upload for today then don't run upload again
$hasTodayUploadResponse = $false
if ($UploadResponseTodayMode -eq 'NameContainsStamp') {
    $hasTodayUploadResponse = Test-HasFileWithStamp -DirectoryPath $ResolvedUploadRespDir -Stamp $todayStamp
}
else {
    $hasTodayUploadResponse = Test-HasTodayFileByCreatedDate -DirectoryPath $ResolvedUploadRespDir -TodayDate $todayDate -Filter $UploadResponseExtFilter -MinSizeBytes $UploadResponseMinSizeBytesForTodayMatch -MaxSizeBytes $UploadResponseMaxSizeBytesForTodayMatch
}

if ($hasTodayUploadResponse) {
    Write-Log -Message "Found today's upload submission response. Skipping upload."
}
else {
    Write-Log -Message "No upload submission response for today. Attempting upload..."
    $uploadOk = Invoke-EligibilityUpload -TransmitPath $ResolvedTransmitDir -UploadResponsePath $ResolvedUploadRespDir -CommandLine $UploadCommand
    if ($uploadOk) { Write-Log -Message "Upload step completed successfully." }
    else { Write-Log -Message "Upload step failed." -Level 'WARN' }
}

# 2) If we have file response for today's submission, don't download
$hasTodayFileResponse = $false
if ($ResponseTodayMode -eq 'NameContainsStamp') {
    $hasTodayFileResponse = Test-HasFileWithStamp -DirectoryPath $ResolvedResponseDir -Stamp $todayStamp
}
else {
    $hasTodayFileResponse = Test-HasTodayFileByCreatedDate -DirectoryPath $ResolvedResponseDir -TodayDate $todayDate -Filter $ResponseExtFilter -MinSizeBytes $ResponseMinSizeBytesForTodayMatch -MaxSizeBytes $ResponseMaxSizeBytesForTodayMatch
}

$downloadSucceeded = $false

if ($hasTodayFileResponse) {
    Write-Log -Message "Found today's response file. Skipping download."
}
else {
    # 3) Else if a transmission file exists try to run the download
    $hasTransmissionFile = $false
    if (Test-Path -Path $ResolvedTransmitDir) {
        $hasTransmissionFile = [bool](Get-ChildItem -Path $ResolvedTransmitDir -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    }

    if ($hasTransmissionFile) {
        Write-Log -Message "No today's response found. Transmission file exists; attempting download..."
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

# 4) On successful response download, move all files (except today's transmit and response) to completed
if ($downloadSucceeded) {
    try {
        Move-OldFilesToCompleted -TransmitPath $ResolvedTransmitDir -ResponsePath $ResolvedResponseDir -CompletedPath $ResolvedCompletedDir -TodayStamp $todayStamp -TodayDate $todayDate
    }
    catch {
        Write-Log -Message ("Archival failed: " + $_.Exception.Message) -Level 'ERROR'
        exit 1
    }
}

Write-Log -Message "Eligibility run complete."