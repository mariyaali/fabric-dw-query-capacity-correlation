# Fabric DW Query Capacity Correlation

This package creates a customer-owned Power BI project that correlates
Microsoft Fabric Capacity Metrics with Query Insights from multiple Fabric
Warehouses. Customers configure, refresh, and publish the report in their own
tenant.

## Package contents

The repository contains `Template`, the configuration script, SQL templates,
an example Warehouse inventory, setup tests, and the customer README. The
customer ZIP excludes repository-only test and build files. It does not contain
configured Warehouse connections or credentials.

The `Configured` output intentionally contains the selected SQL endpoint names,
Warehouse names, Warehouse item IDs, and Capacity Metrics model reference. It
does not contain reusable credentials. Run the configuration script to generate
a new `Configured` project using resources in your tenant.

## What the report shows

- Capacity utilization by hour for the latest 30 days.
- Queries active at any point in the selected hour or time range.
- Query duration, CPU, user, status, scan volume, and SQL text.
- Capacity Metrics artifact kind and the Query Insights distributed statement ID.
- A Warehouse selector spanning every configured SQL endpoint.

A query is active when its execution interval overlaps an hourly window:

```text
Started At < Hour End
Ended At >= Hour Start
```

Running queries use the current time as their effective end. Measures count each
execution once even when it overlaps several hours.

## Prerequisites

- Power BI Desktop with PBIP support.
- Windows PowerShell 5.1 or PowerShell 7.
- Access to the Microsoft Fabric Capacity Metrics semantic model.
- Read and Query Insights access to every included Warehouse.
- Azure CLI authentication for automatic capacity discovery (Option 1 only).
- Fabric administrator permissions for capacity-wide workspace discovery
  (Option 1 only).

## Option 1: Discover all Warehouses on a capacity

In the workspace that contains the Fabric Capacity Metrics semantic model:

1. Open **Workspace settings**.
2. Select **Workspace type**.
3. Under **Connection link**, select the copy icon.

Use the complete copied value as `-CapacityMetricsEndpoint`. The connection
link starts with `powerbi://api.powerbi.com/v1.0/myorg/`. Don't use the
workspace URL from the browser address bar or append the semantic-model name.

Run `az login`, then configure the project with the Fabric capacity ID and the
copied XMLA server:

```powershell
.\Configure-CustomerTemplate.ps1 `
  -CapacityMetricsEndpoint "powerbi://api.powerbi.com/v1.0/myorg/Capacity%20Metrics%20Workspace" `
  -CapacityId "00000000-0000-0000-0000-000000000000"
```

The script first uses the Fabric Admin API to find active workspaces assigned to
the capacity. If the token lacks `Tenant.Read.All`, it falls back to the
workspaces accessible to the signed-in identity. It then lists Warehouse items,
retrieves their SQL endpoints, and generates static Power Query connections.

True capacity-wide discovery requires a Fabric administrator or service
principal token with `Tenant.Read.All` or `Tenant.ReadWrite.All`. Fabric
administrators do not automatically receive data access to every workspace. A
Warehouse is included only when the identity can list workspace items, retrieve
the Warehouse, and query its Query Insights views. The script warns and skips
inaccessible workspaces.

Optional filters accept regular expressions:

```powershell
-WorkspaceNamePattern "^Production" -WarehouseNamePattern "Warehouse$"
```

## Option 2: Supply a Warehouse CSV

Use this method without Fabric administrator permissions or when only selected
Warehouses should be included. Copy the example file, then replace every
`REPLACE-WITH-...` value with details from the customer's Fabric workspace:

```powershell
Copy-Item .\warehouses.example.csv .\warehouses.csv
```

```csv
WorkspaceName,WorkspaceId,WarehouseName,WarehouseItemId,SqlEndpoint
Finance,workspace-guid,FinanceWarehouse,warehouse-guid,your-endpoint.datawarehouse.fabric.microsoft.com
Sales,workspace-guid,SalesWarehouse,warehouse-guid,your-endpoint.datawarehouse.fabric.microsoft.com
```

The SQL endpoint is available in the Warehouse settings or connection details.
Use only the host name, without `https://` or a database suffix. The script
rejects placeholder Warehouse IDs, so the example file cannot accidentally
produce a publishable project.

```powershell
.\Configure-CustomerTemplate.ps1 `
  -CapacityMetricsEndpoint "powerbi://api.powerbi.com/v1.0/myorg/Capacity%20Metrics%20Workspace" `
  -WarehouseConfigPath ".\warehouses.csv"
```

The script creates a separate `Configured` folder and writes the exact included
inventory to `warehouses.configured.csv`. It also writes the normalized Capacity
Metrics XMLA server and semantic-model name to `connection-settings.json`.

Instead of `-CapacityMetricsEndpoint`, you can pass the exact workspace display
name with `-CapacityMetricsWorkspace`. The script converts the display name to
the encoded XMLA server format. For example, spaces appear as `%20`. This
encoding is expected.

The default time-zone settings use Pacific offsets and North American daylight
saving transitions. For another North American zone, pass
`-StandardUtcOffsetHours` and `-DaylightUtcOffsetHours`. For a zone without
daylight saving time, pass the same value for both.

## Open and refresh

1. Open `Configured\Query Capacity Correlation.pbip`.
2. When prompted for the Capacity Metrics source, compare the server and
   semantic-model name with `Configured\connection-settings.json`.
3. Sign in to Capacity Metrics and each configured Warehouse SQL endpoint with
   an account in the same Microsoft Entra tenant as the resources.
4. Set every data-source privacy level to **Organizational**.
5. Review and approve each native Query Insights SQL prompt.
6. Refresh the semantic model.

No views or stored objects are deployed to customer Warehouses. The
configuration script writes a static source block for every endpoint so the
published semantic model can refresh without dynamic-source restrictions.

## Investigate a capacity spike

1. On **Capacity and Query Overview**, select an hour or range with elevated
   utilization.
2. Use Warehouse, artifact kind, status, statement type, and user to narrow the
   query list.
3. Open **Query Investigation** and compare duration, allocated CPU, data
   scanned, and query status.
4. Copy **Distributed Statement ID** to correlate the statement with the
   operation identifier shown by Capacity Metrics.
5. Review the command text and query hash in Query Insights before changing a
   workload. Query Insights excludes system queries and can take time to show a
   completed query.

Capacity Metrics classifies capacity operations as interactive or background
and exposes billing-related fields in its own model. Don't infer billing status
from query duration, front-end activity, or the presence of a distributed
statement ID. Use the classifications supplied by the Capacity Metrics model.

## Troubleshoot setup

### Analysis server name

If Power BI Desktop reports that it can't find the analysis server:

1. Confirm that `connection-settings.json` starts with
   `powerbi://api.powerbi.com/v1.0/myorg/`.
2. In the workspace that contains the **Fabric Capacity Metrics** semantic
   model, open **Workspace settings** > **Workspace type**, and copy the value
   under **Connection link**.
3. Pass the full value with `-CapacityMetricsEndpoint`. Don't append the
   semantic-model name to the server.
4. Confirm that `CapacityMetricsModel` matches the semantic-model display name.
5. Clear the failed Capacity Metrics permission under **File** > **Options and
   settings** > **Data source settings**, and then sign in again.

An encoded workspace segment such as `Capacity%20Metrics%20Workspace` is valid.
The script accepts either the encoded endpoint or the workspace display name
and writes one normalized value.

### Tenant, subscription, or expired permissions

Use an account in the tenant that owns both the Capacity Metrics workspace and
the Warehouses. If the sign-in prompt selects another tenant, sign out of the
failed data source in Power BI Desktop and authenticate again with the correct
organizational account. Reauthenticate when a token or permission has expired.

Azure CLI is required only for automatic capacity discovery. Run `az account
show` to confirm the active tenant before using Option 1. CSV setup doesn't
require an Azure subscription or Fabric administrator permission.

### Missing query rows

Confirm that the signed-in account can query
`queryinsights.exec_requests_history` in each Warehouse. Query Insights retains
historic data for 30 days, excludes system queries, and completed activity can
take up to 15 minutes to appear.

## Configure refresh after publishing

Power BI Desktop credentials are not embedded in the project or transferred to
Power BI Service. After publishing, open the semantic model settings in the
customer workspace. Under **Gateway and cloud connections**, configure or map
every listed Warehouse SQL source and the Capacity Metrics semantic-model
source to customer-owned connections and credentials using Microsoft Entra ID.

Run an on-demand refresh and confirm that it succeeds before sharing the
published report. An OAuth or credentials error means at least one published
source still needs to be configured; it is not resolved by republishing.

## About the Power BI security prompts

Power BI may show a potential security risk or native-query prompt for each
external source. A self-contained multi-endpoint PBIP cannot safely suppress
these prompts per file.

Before approval, compare the displayed sources with
`warehouses.configured.csv`. Keep privacy checks enabled, set all sources to
**Organizational**, and do not use the global **Ignore privacy levels** option.

## Validate before publishing

- The Warehouse selector lists all configured Warehouses.
- The time slicer defaults to the latest 30 days.
- Selecting one hour filters both capacity and query visuals.
- Selecting a range shows queries active anywhere in that range.
- A long-running query appears in every hour it overlapped but counts once.
- `warehouses.configured.csv` contains no skipped or unintended endpoints.

Publish both the report and semantic model from Power BI Desktop into a
customer-owned Fabric workspace. Configure the Service connections described
above, refresh successfully, and then share the report.

## Validate or build the package

Run the setup tests with either supported PowerShell version:

```powershell
.\tests\Test-CustomerTemplate.ps1
```

Build a customer ZIP from the validated repository contents:

```powershell
.\Build-CustomerPackage.ps1 `
  -OutputPath ".\Fabric DW Query Capacity Correlation - Customer Template.zip" `
  -Force
```
