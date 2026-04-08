[CmdletBinding()]
param(
  [string]$GatewayUrl,
  [string]$GatewayToken,
  [string]$ManagementKey,
  [string]$ProviderName,
  [string]$Model,
  [switch]$StartCodexLogin,
  [switch]$StartClaudeLogin,
  [switch]$NoBrowser,
  [int]$PollTimeoutSec = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Import-DotEnv {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }

  Get-Content -LiteralPath $Path | ForEach-Object {
    $line = $_.Trim()
    if (-not $line) { return }
    if ($line.StartsWith("#")) { return }
    $parts = $line -split "=", 2
    if ($parts.Count -ne 2) { return }
    [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), "Process")
  }
}

function Invoke-ManagementRequest {
  param(
    [string]$Uri,
    [string]$ManagementKey,
    [int]$TimeoutSec = 30
  )

  try {
    $response = Invoke-WebRequest -Uri $Uri -Method Get -Headers @{ Authorization = "Bearer $ManagementKey" } -TimeoutSec $TimeoutSec -SkipHttpErrorCheck
    return [PSCustomObject]@{
      StatusCode = [int]$response.StatusCode
      Content = [string]$response.Content
      Error = ""
    }
  } catch {
    return [PSCustomObject]@{
      StatusCode = 0
      Content = ""
      Error = $_.Exception.Message
    }
  }
}

function Try-ParseJson {
  param([string]$Content)
  if (-not $Content) { return $null }
  try {
    return $Content | ConvertFrom-Json -Depth 30
  } catch {
    return $null
  }
}

$root = Split-Path -Parent $PSScriptRoot
Import-DotEnv -Path (Join-Path $root ".env.example")
Import-DotEnv -Path (Join-Path $root ".env")

if (-not $GatewayUrl) {
  if ($env:CLI_PROXY_API_ENDPOINT) {
    $GatewayUrl = $env:CLI_PROXY_API_ENDPOINT
  } elseif (Test-Path -LiteralPath (Join-Path $root ".runtime\\cliproxyapi-state.json")) {
    $state = Get-Content -LiteralPath (Join-Path $root ".runtime\\cliproxyapi-state.json") -Raw | ConvertFrom-Json -Depth 10
    $GatewayUrl = [string]$state.endpoint
  } else {
    $GatewayUrl = "http://127.0.0.1:3000"
  }
}
if (-not $GatewayToken) {
  $GatewayToken = $env:CLI_PROXY_API_KEY
}
if (-not $ManagementKey) {
  $ManagementKey = $env:CLI_PROXY_API_MANAGEMENT_KEY
}
if (-not $ProviderName) {
  $ProviderName = if ($env:CLAUDE_PROVIDER_NAME) { $env:CLAUDE_PROVIDER_NAME } else { "CLIProxyAPI Claude" }
}
if (-not $Model) {
  $Model = if ($env:CLAUDE_PROVIDER_MODEL) { $env:CLAUDE_PROVIDER_MODEL } else { "gpt-5.4" }
}

if (-not $GatewayToken) {
  throw "GatewayToken is required. Set CLI_PROXY_API_KEY or pass -GatewayToken."
}
if (-not $ManagementKey) {
  throw "ManagementKey is required. Set CLI_PROXY_API_MANAGEMENT_KEY or pass -ManagementKey."
}

$GatewayUrl = $GatewayUrl.TrimEnd("/")
$authFilesResponse = Invoke-ManagementRequest -Uri "$GatewayUrl/v0/management/auth-files" -ManagementKey $ManagementKey
if ($authFilesResponse.Error) {
  throw "Failed to query auth files: $($authFilesResponse.Error)"
}

$authFilesPayload = Try-ParseJson -Content $authFilesResponse.Content
$authFiles = @()
if ($authFilesPayload -and $authFilesPayload.files) {
  $authFiles = @($authFilesPayload.files)
}

Write-Host "CLIProxyAPI provider setup"
Write-Host "Gateway : $GatewayUrl"
Write-Host "Provider: $ProviderName"
Write-Host "Model   : $Model"
Write-Host "Auths   : $($authFiles.Count)"
Write-Host ""

if ($StartCodexLogin.IsPresent -or $StartClaudeLogin.IsPresent) {
  $route = if ($StartCodexLogin.IsPresent) { "codex-auth-url" } else { "anthropic-auth-url" }
  $providerLabel = if ($StartCodexLogin.IsPresent) { "Codex" } else { "Claude" }
  $authUrlResponse = Invoke-ManagementRequest -Uri "$GatewayUrl/v0/management/$route?is_webui=true" -ManagementKey $ManagementKey -TimeoutSec 60
  if ($authUrlResponse.Error) {
    throw "Failed to request $providerLabel OAuth URL: $($authUrlResponse.Error)"
  }

  $authUrlPayload = Try-ParseJson -Content $authUrlResponse.Content
  if ($authUrlResponse.StatusCode -lt 200 -or $authUrlResponse.StatusCode -ge 300 -or -not $authUrlPayload.url -or -not $authUrlPayload.state) {
    throw "Failed to request $providerLabel OAuth URL: $($authUrlResponse.Content)"
  }

  $oauthUrl = [string]$authUrlPayload.url
  $oauthState = [string]$authUrlPayload.state

  Write-Host "$providerLabel OAuth URL:"
  Write-Host $oauthUrl
  Write-Host ""

  if (-not $NoBrowser.IsPresent) {
    Start-Process $oauthUrl | Out-Null
    Write-Host "Opened the OAuth URL in your default browser."
  } else {
    Write-Host "NoBrowser enabled. Open the URL manually."
  }

  Write-Host "Waiting for OAuth completion..."
  $deadline = (Get-Date).AddSeconds($PollTimeoutSec)
  $oauthCompleted = $false
  while ((Get-Date) -lt $deadline) {
    $statusResponse = Invoke-ManagementRequest -Uri "$GatewayUrl/v0/management/get-auth-status?state=$oauthState" -ManagementKey $ManagementKey -TimeoutSec 20
    if ($statusResponse.Error) {
      throw "Failed while polling OAuth status: $($statusResponse.Error)"
    }
    $statusPayload = Try-ParseJson -Content $statusResponse.Content
    if ($statusPayload.status -eq "ok") {
      Write-Host "$providerLabel OAuth completed."
      $oauthCompleted = $true
      break
    }
    if ($statusPayload.status -eq "error") {
      throw "$providerLabel OAuth failed: $($statusPayload.error)"
    }
    Start-Sleep -Seconds 2
  }

  if (-not $oauthCompleted) {
    throw "$providerLabel OAuth timed out after $PollTimeoutSec seconds."
  }
}

$modelsResponse = try {
  Invoke-WebRequest -Uri "$GatewayUrl/v1/models" -Method Get -Headers @{ Authorization = "Bearer $GatewayToken" } -TimeoutSec 20 -SkipHttpErrorCheck
} catch {
  $null
}

Write-Host ""
Write-Host "Claude Code environment:"
Write-Host "  ANTHROPIC_BASE_URL=$GatewayUrl"
Write-Host "  ANTHROPIC_AUTH_TOKEN=$GatewayToken"
Write-Host "  ANTHROPIC_MODEL=$Model"
Write-Host "  ANTHROPIC_REASONING_MODEL=$Model"

if ($modelsResponse) {
  $modelsPayload = Try-ParseJson -Content ([string]$modelsResponse.Content)
  $modelCount = 0
  if ($modelsPayload -and $modelsPayload.data) {
    $modelCount = @($modelsPayload.data).Count
  }

  Write-Host ""
  Write-Host "Current /v1/models response:"
  Write-Host ([string]$modelsResponse.Content)

  if ($authFiles.Count -eq 0 -and $modelCount -gt 0) {
    Write-Host ""
    Write-Host "Note: auth_files only shows file-backed OAuth credentials."
    Write-Host "      API-key-backed Codex models can still be available even when Auths = 0."
  }
}
