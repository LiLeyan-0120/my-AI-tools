[CmdletBinding()]
param(
  [string]$ProviderName,
  [string]$GatewayUrl,
  [string]$GatewayToken,
  [string]$ChatModel,
  [string]$ReasoningModel
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

function Get-PythonCommand {
  if (Get-Command py -ErrorAction SilentlyContinue) {
    return [PSCustomObject]@{ Command = "py"; Prefix = @("-3") }
  }
  if (Get-Command python -ErrorAction SilentlyContinue) {
    return [PSCustomObject]@{ Command = "python"; Prefix = @() }
  }

  throw "Python launcher not found. Install Python or ensure 'py' or 'python' is on PATH."
}

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-DotEnv -Path (Join-Path $projectRoot ".env.example")
Import-DotEnv -Path (Join-Path $projectRoot ".env")

if (-not $GatewayUrl) {
  if (Test-Path -LiteralPath (Join-Path $projectRoot ".runtime\\cliproxyapi-state.json")) {
    $state = Get-Content -LiteralPath (Join-Path $projectRoot ".runtime\\cliproxyapi-state.json") -Raw | ConvertFrom-Json -Depth 10
    $GatewayUrl = [string]$state.endpoint
  } elseif ($env:CLI_PROXY_API_ENDPOINT) {
    $GatewayUrl = $env:CLI_PROXY_API_ENDPOINT
  } else {
    $GatewayUrl = "http://127.0.0.1:3000"
  }
}
if (-not $GatewayToken) {
  $GatewayToken = $env:CLI_PROXY_API_KEY
}
if (-not $ProviderName) {
  $ProviderName = if ($env:CLAUDE_PROVIDER_NAME) { $env:CLAUDE_PROVIDER_NAME } else { "CLIProxyAPI Claude" }
}
if (-not $ChatModel) {
  $ChatModel = if ($env:CLAUDE_PROVIDER_MODEL) { $env:CLAUDE_PROVIDER_MODEL } else { "gpt-5.4" }
}
if (-not $ReasoningModel) {
  $ReasoningModel = $ChatModel
}

if (-not $GatewayToken) {
  throw "Gateway token is empty. Set CLI_PROXY_API_KEY first."
}

$python = Get-PythonCommand
$scriptPath = Join-Path $PSScriptRoot "register_cc_switch_provider.py"
$arguments = @(
  $scriptPath,
  "--name", $ProviderName,
  "--gateway-url", $GatewayUrl.TrimEnd("/"),
  "--gateway-token", $GatewayToken,
  "--chat-model", $ChatModel,
  "--reasoning-model", $ReasoningModel,
  "--website-url", $GatewayUrl.TrimEnd("/")
)

& $python.Command @($python.Prefix + $arguments)
