[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "fabric-dw-query-capacity-correlation-" + [Guid]::NewGuid().ToString("N")
)
$csvPath = Join-Path $testRoot "warehouses.csv"
$workspaceOutput = Join-Path $testRoot "Configured-Workspace"
$endpointOutput = Join-Path $testRoot "Configured-Endpoint"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $csv = @"
WorkspaceName,WorkspaceId,WarehouseName,WarehouseItemId,SqlEndpoint
Customer Workspace,11111111-1111-1111-1111-111111111111,Customer Warehouse,22222222-2222-2222-2222-222222222222,customer.datawarehouse.fabric.microsoft.com
"@
    [System.IO.File]::WriteAllText($csvPath, $csv, $utf8NoBom)

    & (Join-Path $root "Configure-CustomerTemplate.ps1") `
        -CapacityMetricsWorkspace "Customer Capacity Metrics" `
        -WarehouseConfigPath $csvPath `
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
        -WarehouseConfigPath $csvPath `
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
