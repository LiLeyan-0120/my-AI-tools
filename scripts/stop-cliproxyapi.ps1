[CmdletBinding()]
param(
  [string]$RuntimeDir = (Join-Path (Split-Path -Parent $PSScriptRoot) ".runtime"),
  [string]$ContainerName = "cliproxyapi-claude-gateway"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeDirAbsolute = [System.IO.Path]::GetFullPath($RuntimeDir)
$statePath = Join-Path $runtimeDirAbsolute "cliproxyapi-state.json"

if (Test-Path -LiteralPath $statePath) {
  try {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -Depth 10
    if ($state.container_name) {
      $ContainerName = [string]$state.container_name
    }
  } catch {
    Write-Warning "Failed to parse state file: $statePath"
  }
}

$existing = docker ps -aq --filter "name=^$ContainerName$"
if ($LASTEXITCODE -ne 0) {
  throw "Failed to inspect Docker containers."
}

if (-not $existing) {
  Write-Host "Container not found: $ContainerName"
  if (Test-Path -LiteralPath $statePath) {
    Remove-Item -LiteralPath $statePath -ErrorAction SilentlyContinue
  }
  exit 0
}

docker rm -f $ContainerName | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Failed to stop container: $ContainerName"
}

if (Test-Path -LiteralPath $statePath) {
  Remove-Item -LiteralPath $statePath -ErrorAction SilentlyContinue
}

Write-Host "Stopped and removed container: $ContainerName"
