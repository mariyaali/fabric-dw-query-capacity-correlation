[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ArchivePath
)

$ErrorActionPreference = "Stop"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "fabric-dw-query-capacity-release-" + [Guid]::NewGuid().ToString("N")
)
$extractPath = Join-Path $testRoot "Package"
$csvPath = Join-Path $extractPath "warehouses.csv"
$ps51Output = Join-Path $extractPath "Configured-PS51"
$ps7Output = Join-Path $extractPath "Configured-PS7"
$expectedEndpoint =
    "powerbi://api.powerbi.com/v1.0/myorg/Customer%20Capacity%20Metrics"
$expectedModel = "Fabric Capacity Metrics"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Test-GeneratedProject {
    param([Parameter(Mandatory)][string]$Path)

    Assert-True `
        -Condition (Test-Path -LiteralPath (
            Join-Path $Path "Query Capacity Correlation.pbip"
        )) `
        -Message "PBIP file is missing from $Path."

    $settings = Get-Content -Raw -Encoding UTF8 -LiteralPath (
        Join-Path $Path "connection-settings.json"
    ) | ConvertFrom-Json
    Assert-True `
        -Condition ($settings.CapacityMetricsEndpoint -eq $expectedEndpoint) `
        -Message "Unexpected Capacity Metrics endpoint in $Path."
    Assert-True `
        -Condition ($settings.CapacityMetricsModel -eq $expectedModel) `
        -Message "Unexpected Capacity Metrics model in $Path."

    $inventory = @(Import-Csv -LiteralPath (
        Join-Path $Path "warehouses.configured.csv"
    ))
    Assert-True `
        -Condition ($inventory.Count -eq 1) `
        -Message "Unexpected Warehouse inventory count in $Path."

    foreach ($jsonFile in Get-ChildItem -LiteralPath $Path -Recurse -Filter *.json) {
        $null = Get-Content -Raw -Encoding UTF8 -LiteralPath $jsonFile.FullName |
            ConvertFrom-Json
    }

    $placeholders = @(
        Get-ChildItem -LiteralPath $Path -Recurse -File |
            Select-String -Pattern "\{\{[A-Z0-9_]+\}\}"
    )
    Assert-True `
        -Condition ($placeholders.Count -eq 0) `
        -Message "Unresolved template placeholders found in $Path."

    $reportFiles = Get-ChildItem -LiteralPath $Path -Recurse -Filter visual.json
    Assert-True `
        -Condition (@(
            $reportFiles | Select-String -SimpleMatch "Artifact Kind"
        ).Count -gt 0) `
        -Message "Artifact Kind isn't present in the generated report."
    Assert-True `
        -Condition (@(
            $reportFiles | Select-String -SimpleMatch "Distributed Statement ID"
        ).Count -gt 0) `
        -Message "Distributed Statement ID isn't present in the generated report."
}

function Get-RelativeFileMap {
    param([Parameter(Mandatory)][string]$Path)

    $map = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -File) {
        $relativePath = [System.IO.Path]::GetRelativePath($Path, $file.FullName)
        $map[$relativePath] = $file.FullName
    }
    return $map
}

try {
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extractPath

    $csv = @"
WorkspaceName,WorkspaceId,WarehouseName,WarehouseItemId,SqlEndpoint
Customer Workspace,11111111-1111-1111-1111-111111111111,Customer Warehouse,22222222-2222-2222-2222-222222222222,customer.datawarehouse.fabric.microsoft.com
"@
    [System.IO.File]::WriteAllText($csvPath, $csv, $utf8NoBom)

    $configureScript = Join-Path $extractPath "Configure-CustomerTemplate.ps1"
    $ps51Args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $configureScript,
        "-CapacityMetricsEndpoint",
        "powerbi://api.powerbi.com/v1.0/myorg/Customer Capacity Metrics",
        "-WarehouseConfigPath", $csvPath,
        "-OutputPath", $ps51Output,
        "-Force"
    )
    & powershell.exe @ps51Args
    Assert-True `
        -Condition ($LASTEXITCODE -eq 0) `
        -Message "Windows PowerShell 5.1 configuration failed."

    $ps7Args = @(
        "-NoProfile",
        "-File", $configureScript,
        "-CapacityMetricsWorkspace", "Customer Capacity Metrics",
        "-WarehouseConfigPath", $csvPath,
        "-OutputPath", $ps7Output,
        "-Force"
    )
    & pwsh.exe @ps7Args
    Assert-True `
        -Condition ($LASTEXITCODE -eq 0) `
        -Message "PowerShell 7 configuration failed."

    Test-GeneratedProject -Path $ps51Output
    Test-GeneratedProject -Path $ps7Output

    $ps51Files = Get-RelativeFileMap -Path $ps51Output
    $ps7Files = Get-RelativeFileMap -Path $ps7Output
    $ps51Names = @($ps51Files.Keys | Sort-Object)
    $ps7Names = @($ps7Files.Keys | Sort-Object)
    Assert-True `
        -Condition (($ps51Names -join "`n") -ceq ($ps7Names -join "`n")) `
        -Message "PowerShell versions generated different file sets."

    $textExtensions = @(
        ".csv", ".json", ".md", ".pbip", ".pbir", ".pbism",
        ".ps1", ".sql", ".tmdl"
    )
    $differences = [System.Collections.Generic.List[string]]::new()
    foreach ($relativePath in $ps51Names) {
        $leftPath = $ps51Files[$relativePath]
        $rightPath = $ps7Files[$relativePath]
        $leftFile = Get-Item -LiteralPath $leftPath
        $isText = (
            $textExtensions -contains $leftFile.Extension.ToLowerInvariant()
        ) -or $leftFile.Name -eq ".platform"

        if ($isText) {
            $left = (Get-Content -Raw -Encoding UTF8 -LiteralPath $leftPath) `
                -replace "`r`n|`r", "`n"
            $right = (Get-Content -Raw -Encoding UTF8 -LiteralPath $rightPath) `
                -replace "`r`n|`r", "`n"
            if ($left -cne $right) {
                $differences.Add($relativePath)
            }
        }
        else {
            $leftHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $leftPath).Hash
            $rightHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $rightPath).Hash
            if ($leftHash -cne $rightHash) {
                $differences.Add($relativePath)
            }
        }
    }

    Assert-True `
        -Condition ($differences.Count -eq 0) `
        -Message (
            "PowerShell versions generated different content:`n" +
            ($differences -join "`n")
        )

    Write-Host (
        (
            "PASS: release archive generated identical {0}-file projects under " +
            "Windows PowerShell 5.1 and PowerShell 7"
        ) -f $ps51Names.Count
    )
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
