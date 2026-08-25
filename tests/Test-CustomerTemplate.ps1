[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "fabric-dw-query-capacity-correlation-" + [Guid]::NewGuid().ToString("N")
)
$workspaceOutput = Join-Path $testRoot "Configured-Workspace"
$endpointOutput = Join-Path $testRoot "Configured-Endpoint"
$capacityId = "33333333-3333-3333-3333-333333333333"

function Assert-Equal {
    param(
        [Parameter(Mandatory)][object]$Actual,
        [Parameter(Mandatory)][object]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message`nExpected: $Expected`nActual: $Actual"
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function az {
    $global:LASTEXITCODE = 0
    return "test-token"
}

function Invoke-RestMethod {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers
    )

    if ($Uri -match '/v1/admin/workspaces\?') {
        return [pscustomobject]@{
            workspaces = @([pscustomobject]@{
                id = "11111111-1111-1111-1111-111111111111"
                name = "Customer Workspace"
            })
            continuationUri = $null
        }
    }

    if ($Uri -match '/items$') {
        return [pscustomobject]@{
            value = @([pscustomobject]@{
                id = "22222222-2222-2222-2222-222222222222"
                displayName = "Customer Warehouse"
                type = "Warehouse"
            })
            continuationUri = $null
        }
    }

    if ($Uri -match '/warehouses/[0-9a-f-]+$') {
        return [pscustomobject]@{
            properties = [pscustomobject]@{
                connectionString = "customer.datawarehouse.fabric.microsoft.com"
            }
        }
    }

    throw "Unexpected mock request: $Uri"
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null

    & (Join-Path $root "Configure-CustomerTemplate.ps1") `
        -CapacityMetricsWorkspace "Customer Capacity Metrics" `
        -CapacityId $capacityId `
        -OutputPath $workspaceOutput

    $expectedEndpoint =
        "powerbi://api.powerbi.com/v1.0/myorg/Customer%20Capacity%20Metrics"
    $workspaceSettings = Get-Content -Raw -Encoding UTF8 -LiteralPath (
        Join-Path $workspaceOutput "connection-settings.json"
    ) | ConvertFrom-Json
    Assert-Equal `
        -Actual $workspaceSettings.CapacityMetricsEndpoint `
        -Expected $expectedEndpoint `
        -Message "Workspace names must produce a normalized XMLA endpoint."

    & (Join-Path $root "Configure-CustomerTemplate.ps1") `
        -CapacityMetricsEndpoint $expectedEndpoint `
        -CapacityId $capacityId `
        -OutputPath $endpointOutput

    $endpointSettings = Get-Content -Raw -Encoding UTF8 -LiteralPath (
        Join-Path $endpointOutput "connection-settings.json"
    ) | ConvertFrom-Json
    Assert-Equal `
        -Actual $endpointSettings.CapacityMetricsEndpoint `
        -Expected $expectedEndpoint `
        -Message "An encoded XMLA endpoint must remain stable."

    $tmdlFiles = Get-ChildItem -LiteralPath $endpointOutput -Recurse -Filter *.tmdl
    $endpointMatches = @(
        $tmdlFiles | Select-String -SimpleMatch $expectedEndpoint
    )
    Assert-True `
        -Condition ($endpointMatches.Count -ge 2) `
        -Message "Generated TMDL doesn't contain the expected XMLA endpoint."

    $placeholders = @(
        Get-ChildItem -LiteralPath $endpointOutput -Recurse -File |
            Select-String -Pattern "\{\{[A-Z0-9_]+\}\}"
    )
    Assert-Equal `
        -Actual $placeholders.Count `
        -Expected 0 `
        -Message "Generated output contains unresolved placeholders."

    $configuredCsv = @(Import-Csv -LiteralPath (
        Join-Path $endpointOutput "warehouses.configured.csv"
    ))
    Assert-Equal `
        -Actual $configuredCsv.Count `
        -Expected 1 `
        -Message "Configured Warehouse inventory has an unexpected row count."

    $jsonFiles = Get-ChildItem -LiteralPath $endpointOutput -Recurse -Filter *.json
    foreach ($jsonFile in $jsonFiles) {
        $null = Get-Content -Raw -Encoding UTF8 -LiteralPath $jsonFile.FullName |
            ConvertFrom-Json
    }

    Write-Host "PASS: customer template configuration and JSON validation"
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
