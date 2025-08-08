@echo off
setlocal EnableDelayedExpansion

:: Ensure PowerShell is available
where powershell >nul 2>&1
if errorlevel 1 (
    echo PowerShell is not available. Exiting script.
    exit /b 1
)

:: Check PowerShell execution policy is accessible
powershell -Command "try { Get-ExecutionPolicy -Scope CurrentUser | Out-Null } catch { exit 1 }" >nul 2>&1
if errorlevel 1 (
    echo PowerShell execution policy prevents running scripts. Exiting script.
    exit /b 1
)

:: Paths and defaults (adjust as needed)
set ROOT=C:\SOLJEN
set TX_DIR=Transmit
set RESPONSE_DIR=Response
:: Use the same directory for upload submission responses
set UPLOAD_RESP_DIR=%RESPONSE_DIR%
set COMPLETED_DIR=Completed
set LOG_DIR=Logs

:: Commands
set DOWNLOAD_CMD=C:\SOLJEN\SEEK_autoT.bat
set POST_CMD=copy "C:\SOLJEN\Batch\Marks_Medicaid_Census.csv" "C:\SOLJEN\Batch\Processed\Marks_Medicaid_Census-%DATE:~10,4%%DATE:~4,2%%DATE:~7,2%_%TIME:~0,2%%TIME:~3,2%.csv"

:: Locate the PowerShell script relative to this .bat
set SCRIPT_DIR=%~dp0
set PS_SCRIPT=%SCRIPT_DIR%eligibility.ps1

if not exist "%PS_SCRIPT%" (
    echo PowerShell script not found: %PS_SCRIPT%
    exit /b 1
)

:: Run the PowerShell script with the configured arguments
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" ^
  -RootDir "%ROOT%" ^
  -TransmitDir "%TX_DIR%" ^
  -ResponseDir "%RESPONSE_DIR%" ^
  -UploadResponseDir "%UPLOAD_RESP_DIR%" ^
  -CompletedDir "%COMPLETED_DIR%" ^
  -LogDir "%LOG_DIR%" ^
  -ResponseTodayMode CreatedDate ^
  -ResponseExtFilter "*.x12" ^
  -ResponseMinSizeBytesForTodayMatch 2049 ^
  -UploadResponseTodayMode CreatedDate ^
  -UploadResponseExtFilter "*.x12" ^
  -UploadResponseMaxSizeBytesForTodayMatch 2048 ^
  -DownloadCommand "'%DOWNLOAD_CMD%'" ^
  -PostDownloadCommand "'%POST_CMD%'"

exit /b %ERRORLEVEL%