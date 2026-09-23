<#
.SYNOPSIS
    Hermes Portable - Windows Reset Utility Script.

.DESCRIPTION
    Deletes downloaded portable runtimes, virtual environments, and source code to trigger
    a clean setup on the next launch. Supports soft reset (preserving user settings and chat
    history) and full reset (completely wiping data and configurations).

.PARAMETER Mode
    Specifies the reset mode to execute:
    - "soft": Deletes .cache/runtimes and src/hermes-agent, but preserves data/ (.env, config.yaml, sessions).
    - "full": Deletes .cache, src/hermes-agent, and data/ (complete wipe).

.EXAMPLE
    .\scripts\reset-windows.ps1 -Mode soft

.EXAMPLE
    .\scripts\reset-windows.ps1 -Mode full
#>

param(
    [ValidateSet("soft", "full")]
    [string]$Mode = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent

# ---------------------------------------------------------------------------
# Interactive Mode Selection Prompt
# ---------------------------------------------------------------------------
# Prompt user for selection if mode parameter was omitted
if (-not $Mode) {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "   Hermes Portable - Reset" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Choose reset mode:" -ForegroundColor Yellow
    Write-Host "  [1] Soft reset  - Delete runtimes + source, keep data/ (API keys, config, history)"
    Write-Host "  [2] Full reset  - Delete everything including data/ (completely fresh start)"
    Write-Host ""
    $choice = Read-Host "Enter 1 or 2"
    if ($choice -eq "2") {
        $Mode = "full"
    } else {
        $Mode = "soft"
    }
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Hermes Portable - Reset ($Mode)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Gateway Process & Lock File Termination
# ---------------------------------------------------------------------------
# Stop any running gateway service and remove auth lock file
$lockFile = Join-Path $Root "data\auth.lock"
if (Test-Path $lockFile) {
    Write-Host "[INFO]  Stopping gateway (removing lock) ..." -ForegroundColor Yellow
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}

# Kill running Python processes matching hermes gateway
Get-Process | Where-Object { $_.ProcessName -like "*python*" -or $_.ProcessName -like "*hermes*" } | ForEach-Object {
    try {
        $cmd = (Get-WmiObject Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine
        if ($cmd -and $cmd -like "*hermes*gateway*") {
            Write-Host "[INFO]  Killing gateway process PID $($_.Id) ..." -ForegroundColor Yellow
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

# ---------------------------------------------------------------------------
# Collect Target Directories to Delete
# ---------------------------------------------------------------------------
$foldersToDelete = @()

$runtimes = Join-Path $Root ".cache\runtimes"
if (Test-Path $runtimes) {
    $foldersToDelete += $runtimes
}

$src = Join-Path $Root "src\hermes-agent"
if (Test-Path $src) {
    $foldersToDelete += $src
}

# Include data and entire .cache folder if full reset was requested
if ($Mode -eq "full") {
    $data = Join-Path $Root "data"
    if (Test-Path $data) {
        $foldersToDelete += $data
    }
    $cache = Join-Path $Root ".cache"
    if (Test-Path $cache) {
        $foldersToDelete += $cache
    }
}

# ---------------------------------------------------------------------------
# Confirmation Prompt
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "The following folders will be DELETED:" -ForegroundColor Yellow
foreach ($f in $foldersToDelete) {
    $size = 0
    if (Test-Path $f) {
        $size = [math]::Round((Get-ChildItem $f -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
    }
    Write-Host "  - $f ($size MB)" -ForegroundColor Red
}

if ($Mode -eq "soft") {
    Write-Host ""
    Write-Host "Your data folder is PRESERVED:" -ForegroundColor Green
    Write-Host "  - $Root\data\.env        (API keys)"
    Write-Host "  - $Root\data\config.yaml  (settings)"
    Write-Host "  - $Root\data\sessions\    (chat history)"
}

Write-Host ""
$confirm = Read-Host "Type 'yes' to confirm deletion"
if ($confirm -ne "yes") {
    Write-Host "Cancelled. Nothing was deleted." -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# Perform Directory Deletion
# ---------------------------------------------------------------------------
foreach ($f in $foldersToDelete) {
    if (Test-Path $f) {
        Write-Host "[DEL]   $f ..." -NoNewline
        Remove-Item $f -Recurse -Force
        Write-Host " done" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "   Reset Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

if ($Mode -eq "soft") {
    Write-Host ""
    Write-Host "Next step: run .\launch.bat to re-download runtimes"
    Write-Host "Your API keys and config are still saved in data\"
} else {
    Write-Host ""
    Write-Host "Next step: run .\launch.bat for a completely fresh start"
    Write-Host "You'll need to re-run the setup wizard and re-enter API keys"
}
