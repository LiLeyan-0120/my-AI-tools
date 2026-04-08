[CmdletBinding()]
param(
  [string]$GatewayUrl,
  [string]$GatewayToken,
  [string]$ManagementKey,
  [string]$Model = "gpt-5.4",
  [string]$ResultsPath,
  [switch]$RequireModel,
  [switch]$SkipMessages
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

function New-Result {
  param(
    [string]$Name,
    [string]$Status,
    [string]$Summary,
    [int]$StatusCode = 0,
    [bool]$Required = $true,
    [object]$Details = $null
  )

  [PSCustomObject]@{
    name = $Name
    status = $Status
    summary = $Summary
    status_code = $StatusCode
    required = $Required
    details = $Details
  }
}

function Invoke-ApiRequest {
  param(
    [string]$Uri,
    [string]$Method,
    [hashtable]$Headers,
    [object]$Body,
    [int]$TimeoutSec = 20
  )

  $params = @{
    Uri = $Uri
    Method = $Method
    Headers = $Headers
    TimeoutSec = $TimeoutSec
    SkipHttpErrorCheck = $true
  }

  if ($null -ne $Body) {
    $params.Body = $Body | ConvertTo-Json -Depth 30 -Compress
    $params.ContentType = "application/json"
  }

  try {
    $response = Invoke-WebRequest @params
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

function Get-AnthropicText {
  param([object]$Payload)

  $text = ""
  $contentProperty = $null
  if ($Payload) {
    $contentProperty = $Payload.PSObject.Properties["content"]
  }
  if ($contentProperty -and $contentProperty.Value) {
    foreach ($block in @($contentProperty.Value)) {
      if ($block.type -eq "text" -and $block.text) {
        $text += [string]$block.text
      }
    }
  }
  return $text.Trim()
}

function Get-FirstToolUseBlock {
  param([object]$Payload)

  $contentProperty = $null
  if ($Payload) {
    $contentProperty = $Payload.PSObject.Properties["content"]
  }
  if (-not $contentProperty -or -not $contentProperty.Value) {
    return $null
  }

  foreach ($block in @($contentProperty.Value)) {
    if ($block.type -eq "tool_use" -and $block.id -and $block.name) {
      return $block
    }
  }

  return $null
}

function Get-ApiErrorSummary {
  param(
    [string]$RawContent,
    [object]$ParsedPayload
  )

  if ($ParsedPayload) {
    $errorProperty = $ParsedPayload.PSObject.Properties["error"]
    if ($errorProperty -and $errorProperty.Value) {
      $messageProperty = $errorProperty.Value.PSObject.Properties["message"]
      if ($messageProperty -and $messageProperty.Value) {
        return [string]$messageProperty.Value
      }
    }
  }

  return $RawContent
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

if (-not $GatewayToken) {
  throw "GatewayToken is required. Set CLI_PROXY_API_KEY or pass -GatewayToken."
}
if (-not $ManagementKey) {
  throw "ManagementKey is required. Set CLI_PROXY_API_MANAGEMENT_KEY or pass -ManagementKey."
}

$GatewayUrl = $GatewayUrl.TrimEnd("/")

$health = Invoke-ApiRequest -Uri "$GatewayUrl/" -Method "GET" -Headers @{} -TimeoutSec 15
$models = Invoke-ApiRequest -Uri "$GatewayUrl/v1/models" -Method "GET" -Headers @{ Authorization = "Bearer $GatewayToken" } -TimeoutSec 20
$authFiles = Invoke-ApiRequest -Uri "$GatewayUrl/v0/management/auth-files" -Method "GET" -Headers @{ Authorization = "Bearer $ManagementKey" } -TimeoutSec 20

$results = [System.Collections.Generic.List[object]]::new()

if ($health.Error) {
  $results.Add((New-Result -Name "health" -Status "fail" -Summary $health.Error -Required $true))
} else {
  $results.Add((New-Result -Name "health" -Status $(if ($health.StatusCode -ge 200 -and $health.StatusCode -lt 300) { "pass" } else { "fail" }) -Summary "GET / returned $($health.StatusCode)" -StatusCode $health.StatusCode -Required $true))
}

$modelsParsed = Try-ParseJson -Content $models.Content
$modelIds = @()
if ($modelsParsed -and $modelsParsed.data) {
  foreach ($item in $modelsParsed.data) {
    if ($item.id) {
      $modelIds += [string]$item.id
    }
  }
}

if ($models.Error) {
  $results.Add((New-Result -Name "models" -Status "fail" -Summary $models.Error -Required $RequireModel.IsPresent))
} elseif ($models.StatusCode -ge 200 -and $models.StatusCode -lt 300) {
  if ($modelIds.Count -gt 0) {
    $results.Add((New-Result -Name "models" -Status "pass" -Summary ("models=" + ($modelIds -join ", ")) -StatusCode $models.StatusCode -Required $RequireModel.IsPresent -Details $modelIds))
  } else {
    $results.Add((New-Result -Name "models" -Status "warn" -Summary "Gateway is reachable but no models are available yet. OAuth/provider auth is probably still missing." -StatusCode $models.StatusCode -Required $RequireModel.IsPresent))
  }
} else {
  $results.Add((New-Result -Name "models" -Status "fail" -Summary $models.Content -StatusCode $models.StatusCode -Required $RequireModel.IsPresent))
}

$authParsed = Try-ParseJson -Content $authFiles.Content
$authCount = 0
if ($authParsed -and $authParsed.files) {
  $authCount = @($authParsed.files).Count
}
if ($authFiles.Error) {
  $results.Add((New-Result -Name "auth_files" -Status "fail" -Summary $authFiles.Error -Required $false))
} elseif ($authFiles.StatusCode -ge 200 -and $authFiles.StatusCode -lt 300) {
  $results.Add((New-Result -Name "auth_files" -Status $(if ($authCount -gt 0) { "pass" } else { "warn" }) -Summary "auth_files=$authCount" -StatusCode $authFiles.StatusCode -Required $false -Details $authParsed))
} else {
  $results.Add((New-Result -Name "auth_files" -Status "fail" -Summary $authFiles.Content -StatusCode $authFiles.StatusCode -Required $false))
}

$canRunModelChecks = ($modelIds -contains $Model)
if (-not $SkipMessages.IsPresent) {
  if (-not $canRunModelChecks) {
    $results.Add((New-Result -Name "messages" -Status "skipped" -Summary "Model '$Model' is not available yet, so Claude-facing message checks were skipped." -Required $RequireModel.IsPresent))
  } else {
    $messageBody = @{
      model = $Model
      max_tokens = 8
      stream = $false
      messages = @(
        @{
          role = "user"
          content = "reply exactly: OK"
        }
      )
    }
    $messageResponse = Invoke-ApiRequest -Uri "$GatewayUrl/v1/messages" -Method "POST" -Headers @{
      "x-api-key" = $GatewayToken
      "anthropic-version" = "2023-06-01"
    } -Body $messageBody -TimeoutSec 30
    if ($messageResponse.Error) {
      $results.Add((New-Result -Name "messages" -Status "fail" -Summary $messageResponse.Error -Required $RequireModel.IsPresent))
    } else {
      $parsed = Try-ParseJson -Content $messageResponse.Content
      $text = Get-AnthropicText -Payload $parsed
      $status = if ($messageResponse.StatusCode -ge 200 -and $messageResponse.StatusCode -lt 300 -and $text) { "pass" } else { "fail" }
      $summary = if ($text) { $text } else { Get-ApiErrorSummary -RawContent $messageResponse.Content -ParsedPayload $parsed }
      $results.Add((New-Result -Name "messages" -Status $status -Summary $summary -StatusCode $messageResponse.StatusCode -Required $RequireModel.IsPresent -Details $parsed))
    }

    $toolPrompt = "Use the echo_result tool with text set to OK. After you receive the tool result, reply exactly: TOOL_OK"
    $toolSchema = @(
      @{
        name = "echo_result"
        description = "Echoes the provided text back to the assistant."
        input_schema = @{
          type = "object"
          properties = @{
            text = @{
              type = "string"
            }
          }
          required = @("text")
        }
      }
    )

    $toolRequestBody = @{
      model = $Model
      max_tokens = 96
      stream = $false
      messages = @(
        @{
          role = "user"
          content = $toolPrompt
        }
      )
      tools = $toolSchema
      tool_choice = @{
        type = "tool"
        name = "echo_result"
      }
    }

    $toolRequestResponse = Invoke-ApiRequest -Uri "$GatewayUrl/v1/messages" -Method "POST" -Headers @{
      "x-api-key" = $GatewayToken
      "anthropic-version" = "2023-06-01"
    } -Body $toolRequestBody -TimeoutSec 45

    if ($toolRequestResponse.Error) {
      $results.Add((New-Result -Name "tool_request" -Status "fail" -Summary $toolRequestResponse.Error -Required $RequireModel.IsPresent))
    } else {
      $toolRequestParsed = Try-ParseJson -Content $toolRequestResponse.Content
      $toolUseBlock = Get-FirstToolUseBlock -Payload $toolRequestParsed
      $toolRequestStatus = if ($toolRequestResponse.StatusCode -ge 200 -and $toolRequestResponse.StatusCode -lt 300 -and $toolUseBlock) { "pass" } else { "fail" }
      $toolRequestSummary = if ($toolUseBlock) {
        "tool_use name=$($toolUseBlock.name) id=$($toolUseBlock.id)"
      } else {
        Get-ApiErrorSummary -RawContent $toolRequestResponse.Content -ParsedPayload $toolRequestParsed
      }
      $results.Add((New-Result -Name "tool_request" -Status $toolRequestStatus -Summary $toolRequestSummary -StatusCode $toolRequestResponse.StatusCode -Required $RequireModel.IsPresent -Details $toolRequestParsed))

      if ($toolUseBlock) {
        $toolRoundtripBody = @{
          model = $Model
          max_tokens = 32
          stream = $false
          messages = @(
            @{
              role = "user"
              content = $toolPrompt
            },
            @{
              role = "assistant"
              content = @($toolRequestParsed.content)
            },
            @{
              role = "user"
              content = @(
                @{
                  type = "tool_result"
                  tool_use_id = [string]$toolUseBlock.id
                  content = "OK"
                }
              )
            }
          )
          tools = $toolSchema
        }

        $toolRoundtripResponse = Invoke-ApiRequest -Uri "$GatewayUrl/v1/messages" -Method "POST" -Headers @{
          "x-api-key" = $GatewayToken
          "anthropic-version" = "2023-06-01"
        } -Body $toolRoundtripBody -TimeoutSec 45

        if ($toolRoundtripResponse.Error) {
          $results.Add((New-Result -Name "tool_roundtrip" -Status "fail" -Summary $toolRoundtripResponse.Error -Required $RequireModel.IsPresent))
        } else {
          $toolRoundtripParsed = Try-ParseJson -Content $toolRoundtripResponse.Content
          $toolRoundtripText = Get-AnthropicText -Payload $toolRoundtripParsed
          $toolRoundtripStatus = if (
            $toolRoundtripResponse.StatusCode -ge 200 -and
            $toolRoundtripResponse.StatusCode -lt 300 -and
            $toolRoundtripText -match "TOOL_OK"
          ) { "pass" } else { "fail" }
          $toolRoundtripSummary = if ($toolRoundtripText) { $toolRoundtripText } else { Get-ApiErrorSummary -RawContent $toolRoundtripResponse.Content -ParsedPayload $toolRoundtripParsed }
          $results.Add((New-Result -Name "tool_roundtrip" -Status $toolRoundtripStatus -Summary $toolRoundtripSummary -StatusCode $toolRoundtripResponse.StatusCode -Required $RequireModel.IsPresent -Details $toolRoundtripParsed))
        }
      }
    }
  }
}

$requiredFailures = @($results | Where-Object { $_.required -and $_.status -eq "fail" })
$exitCode = if ($requiredFailures.Count -gt 0) { 1 } else { 0 }

Write-Host "=== CLIProxyAPI Gateway Diagnostics ==="
Write-Host "Gateway: $GatewayUrl"
Write-Host "Model  : $Model"
Write-Host ""
foreach ($result in $results) {
  Write-Host ("[{0}] {1}" -f $result.status.ToUpperInvariant(), $result.name)
  Write-Host ("  required: {0}" -f $result.required)
  Write-Host ("  status  : {0}" -f $result.status_code)
  Write-Host ("  detail  : {0}" -f $result.summary)
  Write-Host ""
}

$payload = [PSCustomObject]@{
  tested_at = (Get-Date).ToString("o")
  gateway_url = $GatewayUrl
  model = $Model
  exit_code = $exitCode
  results = $results
}

if ($ResultsPath) {
  $payload | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ResultsPath -Encoding UTF8
}

exit $exitCode
