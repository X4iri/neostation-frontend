#!/usr/bin/env pwsh
# Run NeoStation in release mode with environment variables from .env
# Usage: .\run-release.ps1
# Or with a custom env file: .\run-release.ps1 -EnvFile .\.env.local

param(
    [string]$EnvFile = ".env"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $EnvFile)) {
    Write-Error "Environment file not found: $EnvFile"
    exit 1
}

# Step 1: Ensure dependencies are resolved and windows/flutter exists
$flutterDir = "windows\flutter"
if (-not (Test-Path "$flutterDir\CMakeLists.txt")) {
    Write-Host "Regenerating Flutter Windows directory..." -ForegroundColor Yellow
    flutter pub get
}

# Step 2: Clean stale plugin symlinks BEFORE the build phase.
# Flutter's pub get creates .plugin_symlinks entries as regular directories
# when the system doesn't support symlinks (common on Windows without
# Developer Mode). The build phase then fails trying to create symlinks
# over those existing directories. We delete them here so the build can
# create fresh symlinks.
$pluginSymlinks = "windows\flutter\ephemeral\.plugin_symlinks"
if (Test-Path $pluginSymlinks) {
    Remove-Item -Recurse -Force $pluginSymlinks -ErrorAction SilentlyContinue
    Write-Host "Cleaned stale plugin symlinks" -ForegroundColor Yellow
}

# Step 3: Run with --no-pub so flutter run does NOT run pub get again
# (which would recreate .plugin_symlinks as directories before the build)
Write-Host "Loading environment from: $EnvFile" -ForegroundColor Cyan
flutter run --release --no-pub --dart-define-from-file=$EnvFile @args
