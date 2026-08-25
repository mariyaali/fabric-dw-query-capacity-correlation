[CmdletBinding()]
param(
    [Parameter()]
    [string]$CapacityMetricsWorkspace,

    [Parameter()]
    [string]$CapacityMetricsEndpoint,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CapacityMetricsModel = "Fabric Capacity Metrics",

    [Parameter(Mandatory)]
    [ValidatePattern(
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    )]
    [string]$CapacityId,

    [Parameter()]
    [string]$WorkspaceNamePattern = ".*",

    [Parameter()]
    [string]$WarehouseNamePattern = ".*",

    [Parameter()]
    [ValidateRange(-14, 14)]
    [int]$StandardUtcOffsetHours = -8,

    [Parameter()]
    [ValidateRange(-14, 14)]
    [int]$DaylightUtcOffsetHours = -7,

    [Parameter()]
    [string]$OutputPath = (Join-Path $PSScriptRoot "Configured"),

    [switch]$Force
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-FabricAccessToken {
    $token = az account get-access-token `
        --resource "https://api.fabric.microsoft.com" `
        --query accessToken `
        --output tsv

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Could not acquire a Fabric token. Run 'az login' and try again."
    }

    return $token.Trim()
}

function Invoke-FabricGet {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$Token
    )

    Invoke-RestMethod `
        -Method Get `
        -Uri $Uri `
        -Headers @{ Authorization = "Bearer $Token" }
}

function Get-FabricCollection {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$CollectionProperty,

        [Parameter(Mandatory)]
        [string]$Token
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $nextUri = $Uri

    while ($nextUri) {
        $response = Invoke-FabricGet -Uri $nextUri -Token $Token
        foreach ($item in $response.$CollectionProperty) {
            $results.Add($item)
        }
        $nextUri = $response.continuationUri
    }

    return $results
}

function Get-WarehousesForCapacity {
    param(
        [Parameter(Mandatory)]
        [string]$Capacity,

        [Parameter(Mandatory)]
        [string]$WorkspacePattern,

        [Parameter(Mandatory)]
        [string]$WarehousePattern
    )

    $token = Get-FabricAccessToken
    try {
        $workspaceUri =
            "https://api.fabric.microsoft.com/v1/admin/workspaces" +
            "?capacityId=$Capacity&state=Active&type=Workspace"
        $workspaces = Get-FabricCollection `
            -Uri $workspaceUri `
            -CollectionProperty "workspaces" `
            -Token $token |
            Where-Object { $_.name -match $WorkspacePattern }
    }
    catch {
        Write-Warning (
            "Capacity-wide admin discovery was unavailable: {0}" -f
            $_.Exception.Message
        )
        Write-Warning (
            "Falling back to workspaces accessible to the signed-in identity."
        )

        $workspaceUri = "https://api.fabric.microsoft.com/v1/workspaces"
        $workspaces = Get-FabricCollection `
            -Uri $workspaceUri `
            -CollectionProperty "value" `
            -Token $token |
            Where-Object {
                $_.capacityId -eq $Capacity -and
                $_.displayName -match $WorkspacePattern
            } |
            ForEach-Object {
                [pscustomobject]@{
                    id = $_.id
                    name = $_.displayName
                }
            }
    }

    $warehouses = [System.Collections.Generic.List[object]]::new()

    foreach ($workspace in $workspaces) {
        try {
            $itemsUri =
                "https://api.fabric.microsoft.com/v1/workspaces/" +
                "$($workspace.id)/items"
            $items = Get-FabricCollection `
                -Uri $itemsUri `
                -CollectionProperty "value" `
                -Token $token |
                Where-Object {
                    $_.type -eq "Warehouse" -and
                    $_.displayName -match $WarehousePattern
                }

            foreach ($item in $items) {
                $warehouseUri =
                    "https://api.fabric.microsoft.com/v1/workspaces/" +
                    "$($workspace.id)/warehouses/$($item.id)"
                $warehouse = Invoke-FabricGet -Uri $warehouseUri -Token $token
                $server = $warehouse.properties.connectionString

                if ([string]::IsNullOrWhiteSpace($server)) {
                    Write-Warning (
                        "Skipping '{0}' in '{1}': no SQL endpoint was returned." -f
                        $item.displayName,
                        $workspace.name
                    )
                    continue
                }

                $warehouses.Add([pscustomobject]@{
                    WorkspaceName = $workspace.name
                    WorkspaceId = $workspace.id
                    WarehouseName = $item.displayName
                    WarehouseItemId = $item.id
                    SqlEndpoint = $server
                })
            }
        }
        catch {
            Write-Warning (
                "Skipping workspace '{0}': {1}" -f
                $workspace.name,
                $_.Exception.Message
            )
        }
    }

    return $warehouses
}

function ConvertTo-MString {
    param([Parameter(Mandatory)][string]$Value)
    return '"' + $Value.Replace('"', '""') + '"'
}

function Resolve-CapacityMetricsEndpoint {
    param(
        [string]$Workspace,
        [string]$Endpoint
    )

    $xmlaPrefix = "powerbi://api.powerbi.com/v1.0/myorg/"
    $candidate = if (-not [string]::IsNullOrWhiteSpace($Endpoint)) {
        $Endpoint.Trim()
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Workspace)) {
        $Workspace.Trim()
    }
    else {
        throw (
            "Specify -CapacityMetricsWorkspace or -CapacityMetricsEndpoint. " +
            "Use the workspace that contains the Fabric Capacity Metrics semantic model."
        )
    }

    if ($candidate.StartsWith($xmlaPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $workspaceSegment = $candidate.Substring($xmlaPrefix.Length).TrimEnd("/")
    }
    elseif ($candidate -match '^powerbi://') {
        throw (
            "Unsupported Capacity Metrics XMLA endpoint. Expected an endpoint that starts " +
            "with '$xmlaPrefix'."
        )
    }
    else {
        $workspaceSegment = $candidate
    }

    if ([string]::IsNullOrWhiteSpace($workspaceSegment)) {
        throw "The Capacity Metrics XMLA endpoint does not contain a workspace name."
    }

    if ($workspaceSegment.Contains("?") -or $workspaceSegment.Contains("#")) {
        throw "The Capacity Metrics XMLA endpoint must not contain a query string or fragment."
    }

    try {
        $workspaceName = [Uri]::UnescapeDataString($workspaceSegment)
        $encodedWorkspace = [Uri]::EscapeDataString($workspaceName)
    }
    catch {
        throw "The Capacity Metrics workspace or XMLA endpoint contains invalid escaping."
    }

    return $xmlaPrefix + $encodedWorkspace
}

function Convert-SqlTo-MString {
    param([Parameter(Mandatory)][string]$Sql)
    $normalized = $Sql -replace "`r`n|`r|`n", "#(lf)"
    return ConvertTo-MString -Value $normalized
}

function New-CombinedWarehouseM {
    param(
        [Parameter(Mandatory)]
        [object[]]$Warehouses,

        [Parameter(Mandatory)]
        [string]$SqlTemplate,

        [Parameter(Mandatory)]
        [int]$StandardOffset,

        [Parameter(Mandatory)]
        [int]$DaylightOffset
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $sourceNames = [System.Collections.Generic.List[string]]::new()
    $lines.Add("`t`t`t`tlet")

    for ($index = 0; $index -lt $Warehouses.Count; $index++) {
        $warehouse = $Warehouses[$index]
        $sourceName = "Warehouse{0:D3}" -f ($index + 1)
        $sourceNames.Add($sourceName)

        $sql = $SqlTemplate.
            Replace(
                "{{WAREHOUSE_ITEM_ID}}",
                ([string]$warehouse.WarehouseItemId).ToUpperInvariant()
            ).
            Replace(
                "{{WAREHOUSE_NAME}}",
                ([string]$warehouse.WarehouseName).Replace("'", "''")
            ).
            Replace("{{STANDARD_UTC_OFFSET}}", $StandardOffset.ToString()).
            Replace("{{DAYLIGHT_UTC_OFFSET}}", $DaylightOffset.ToString())

        $comma = if ($index -lt $Warehouses.Count - 1) { "," } else { "," }
        $lines.Add("`t`t`t`t    $sourceName = Value.NativeQuery(")
        $lines.Add(
            "`t`t`t`t        Sql.Database(" +
            "$(ConvertTo-MString $warehouse.SqlEndpoint), " +
            "$(ConvertTo-MString $warehouse.WarehouseName)),"
        )
        $lines.Add(
            "`t`t`t`t        $(Convert-SqlTo-MString $sql),"
        )
        $lines.Add("`t`t`t`t        null,")
        $lines.Add("`t`t`t`t        [EnableFolding = false]")
        $lines.Add("`t`t`t`t    )$comma")
    }

    $lines.Add(
        "`t`t`t`t    Source = Table.Combine({" +
        ($sourceNames -join ", ") +
        "})"
    )
    $lines.Add("`t`t`t`tin")
    $lines.Add("`t`t`t`t    Source")
    return $lines -join "`r`n"
}

function New-HourWindowsM {
    param(
        [Parameter(Mandatory)]
        [int]$StandardOffset,

        [Parameter(Mandatory)]
        [int]$DaylightOffset
    )

    @"
				let
				    UtcNow = DateTimeZone.RemoveZone(DateTimeZone.UtcNow()),
				    CurrentYear = Date.Year(UtcNow),
				    March8 = #date(CurrentYear, 3, 8),
				    November1 = #date(CurrentYear, 11, 1),
				    DstStartDate = Date.AddDays(
				        March8,
				        Number.Mod(7 - Date.DayOfWeek(March8, Day.Sunday), 7)
				    ),
				    DstEndDate = Date.AddDays(
				        November1,
				        Number.Mod(7 - Date.DayOfWeek(November1, Day.Sunday), 7)
				    ),
				    DstStartUtc = DateTime.From(DstStartDate)
				        + #duration(0, $(2 - $StandardOffset), 0, 0),
				    DstEndUtc = DateTime.From(DstEndDate)
				        + #duration(0, $(2 - $DaylightOffset), 0, 0),
				    CurrentOffset = if UtcNow >= DstStartUtc and UtcNow < DstEndUtc
				        then $DaylightOffset
				        else $StandardOffset,
				    LocalNow = UtcNow + #duration(0, CurrentOffset, 0, 0),
				    EndHour = #datetime(
				        Date.Year(LocalNow),
				        Date.Month(LocalNow),
				        Date.Day(LocalNow),
				        Time.Hour(Time.From(LocalNow)),
				        0,
				        0
				    ),
				    StartHour = EndHour - #duration(30, 0, 0, 0),
				    Hours = List.DateTimes(
				        StartHour,
				        721,
				        #duration(0, 1, 0, 0)
				    ),
				    Source = Table.FromList(
				        Hours,
				        Splitter.SplitByNothing(),
				        {"Timestamp"},
				        null,
				        ExtraValues.Error
				    ),
				    Typed = Table.TransformColumnTypes(
				        Source,
				        {{"Timestamp", type datetime}}
				    )
				in
				    Typed
"@
}

$templatePath = Join-Path $PSScriptRoot "Template"
if (-not (Test-Path -LiteralPath $templatePath)) {
    throw "Template folder not found: $templatePath"
}

$warehouses = @(
    Get-WarehousesForCapacity `
        -Capacity $CapacityId `
        -WorkspacePattern $WorkspaceNamePattern `
        -WarehousePattern $WarehouseNamePattern
)

$requiredColumns = "WarehouseName", "WarehouseItemId", "SqlEndpoint"
foreach ($column in $requiredColumns) {
    if (-not $warehouses -or -not ($warehouses[0].PSObject.Properties.Name -contains $column)) {
        throw "Warehouse discovery results must include the '$column' property."
    }
}

$warehouses = @(
    $warehouses |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.WarehouseName) -and
            -not [string]::IsNullOrWhiteSpace($_.WarehouseItemId) -and
            -not [string]::IsNullOrWhiteSpace($_.SqlEndpoint)
        } |
        Sort-Object WorkspaceName, WarehouseName, WarehouseItemId -Unique
)

if ($warehouses.Count -eq 0) {
    throw "No accessible Warehouses matched the requested configuration."
}

foreach ($warehouse in $warehouses) {
    if ($warehouse.WarehouseItemId -notmatch
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "Invalid Warehouse item ID: $($warehouse.WarehouseItemId)"
    }
}

if (Test-Path -LiteralPath $OutputPath) {
    if (-not $Force) {
        throw "Output folder already exists. Use -Force or choose another -OutputPath."
    }
    Remove-Item -LiteralPath $OutputPath -Recurse -Force
}

New-Item -ItemType Directory -Path $OutputPath | Out-Null
Copy-Item -Path (Join-Path $templatePath "*") -Destination $OutputPath -Recurse

$executionSql = Get-Content -Raw -Encoding UTF8 -LiteralPath (
    Join-Path $PSScriptRoot "query-executions.template.sql"
)
$detailSql = Get-Content -Raw -Encoding UTF8 -LiteralPath (
    Join-Path $PSScriptRoot "query-details.template.sql"
)

$executionM = New-CombinedWarehouseM `
    -Warehouses $warehouses `
    -SqlTemplate $executionSql `
    -StandardOffset $StandardUtcOffsetHours `
    -DaylightOffset $DaylightUtcOffsetHours
$detailM = New-CombinedWarehouseM `
    -Warehouses $warehouses `
    -SqlTemplate $detailSql `
    -StandardOffset $StandardUtcOffsetHours `
    -DaylightOffset $DaylightUtcOffsetHours
$hourWindowsM = New-HourWindowsM `
    -StandardOffset $StandardUtcOffsetHours `
    -DaylightOffset $DaylightUtcOffsetHours

$capacityEndpoint = Resolve-CapacityMetricsEndpoint `
    -Workspace $CapacityMetricsWorkspace `
    -Endpoint $CapacityMetricsEndpoint

$replacements = [ordered]@{
    "{{CAPACITY_METRICS_ENDPOINT}}" = $capacityEndpoint
    "{{CAPACITY_METRICS_MODEL}}" = $CapacityMetricsModel.Replace('"', '""')
    "{{QUERY_EXECUTIONS_M}}" = $executionM
    "{{QUERY_DETAILS_M}}" = $detailM
    "{{HOUR_WINDOWS_M}}" = $hourWindowsM
}

$configurableFiles = Get-ChildItem -LiteralPath $OutputPath -Recurse -File |
    Where-Object { $_.Extension -eq ".tmdl" }

foreach ($file in $configurableFiles) {
    $content = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName
    foreach ($entry in $replacements.GetEnumerator()) {
        $content = $content.Replace($entry.Key, $entry.Value)
    }
    [System.IO.File]::WriteAllText($file.FullName, $content, $utf8NoBom)
}

$warehouseCsv = @($warehouses | ConvertTo-Csv -NoTypeInformation)
[System.IO.File]::WriteAllLines(
    (Join-Path $OutputPath "warehouses.configured.csv"),
    $warehouseCsv,
    $utf8NoBom
)

$connectionSettings = [ordered]@{
    CapacityMetricsEndpoint = $capacityEndpoint
    CapacityMetricsModel = $CapacityMetricsModel
    WarehouseCount = $warehouses.Count
}
$connectionSettingsJson = $connectionSettings | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText(
    (Join-Path $OutputPath "connection-settings.json"),
    $connectionSettingsJson,
    $utf8NoBom
)

$unresolved = Get-ChildItem -LiteralPath $OutputPath -Recurse -File |
    Select-String -Pattern "\{\{[A-Z0-9_]+\}\}"
if ($unresolved) {
    $locations = $unresolved |
        ForEach-Object { "$($_.Path):$($_.LineNumber)" } |
        Sort-Object -Unique
    throw "Configuration left unresolved placeholders:`n$($locations -join "`n")"
}

$pbipPath = Join-Path $OutputPath "Query Capacity Correlation.pbip"
Write-Host ""
Write-Host "Customer project created with $($warehouses.Count) Warehouses:" `
    -ForegroundColor Green
Write-Host "  $pbipPath"
Write-Host ""
Write-Host "Capacity Metrics connection:"
Write-Host "  Server: $capacityEndpoint"
Write-Host "  Semantic model: $CapacityMetricsModel"
Write-Host "  Saved to: $(Join-Path $OutputPath 'connection-settings.json')"
Write-Host ""
Write-Host "Next steps:"
Write-Host "1. Open the PBIP file in Power BI Desktop."
Write-Host "2. Confirm the Capacity Metrics server and semantic model match connection-settings.json."
Write-Host "3. Sign in to Capacity Metrics and each SQL endpoint with an account in the same tenant."
Write-Host "4. Set every source privacy level to Organizational."
Write-Host "5. Review and approve each native Query Insights SQL prompt."
Write-Host "6. Refresh, validate the report, and publish it to the customer's workspace."
Write-Host "7. Configure every published source under Gateway and cloud connections."
Write-Host "8. Run a successful Service refresh before sharing the report."
