# Fabric DW Query Capacity Correlation

This customer-owned Power BI report correlates Microsoft Fabric Capacity
Metrics with Query Insights from Fabric Warehouses. Use it to identify which
queries contributed to a capacity spike, compare Warehouse activity, and
validate tuning or scheduling changes.

## What the report shows

- Capacity utilization by hour for the latest 30 days.
- Queries active during the selected hour or time range.
- Query duration, CPU, user, status, scan volume, and SQL text.
- Warehouse, artifact kind, and distributed statement ID.

## Prerequisites

- Power BI Desktop with PBIP support.
- Windows PowerShell 5.1 or PowerShell 7.
- Azure CLI.
- Access to the **Fabric Capacity Metrics** semantic model.
- Read and Query Insights access to each Warehouse.

## Configure the report

### 1. Get the Capacity ID

1. In Fabric, select **Settings** > **Admin portal**.
2. Open **Capacity settings** and select the capacity.
3. Copy the GUID after `/capacities/` in the browser URL.

### 2. Get the Capacity Metrics workspace name

1. Open **OneLake catalog** in Fabric.
2. Filter to **Semantic model** and search for **Fabric Capacity Metrics**.
3. Copy the exact value in the **Workspace** column.

The workspace typically resembles:

```text
Microsoft Fabric Capacity Metrics <installation date and time>
```

If it isn't visible, ask the person who installed the Fabric Capacity Metrics
app for the workspace name or access. Do not use a workspace that only contains
Warehouses.

### 3. Run the configuration script

Sign in with `az login`, then run:

```powershell
.\Configure-CustomerTemplate.ps1 `
  -CapacityId "00000000-0000-0000-0000-000000000000" `
  -CapacityMetricsWorkspace "Microsoft Fabric Capacity Metrics <installation>"
```

The script discovers accessible Warehouses on the capacity and creates a
`Configured` folder. It constructs the required Capacity Metrics connection;
customers do not need to find or edit an XMLA endpoint.

Capacity-wide discovery requires Fabric administrator or service-principal
permissions with `Tenant.Read.All` or `Tenant.ReadWrite.All`. Without those
permissions, the script uses only workspaces accessible to the signed-in user.

Optional filters:

```powershell
-WorkspaceNamePattern "^Production" -WarehouseNamePattern "Warehouse$"
```

## Open and refresh

1. Open `Configured\Query Capacity Correlation.pbip`.
2. Sign in to Capacity Metrics and each Warehouse SQL endpoint.
3. Set every source's privacy level to **Organizational**.
4. Review and approve the native Query Insights prompts.
5. Refresh the semantic model.

After publishing, configure each source under **Semantic model settings** >
**Gateway and cloud connections**, then run an on-demand refresh.

## Common issues

### `PowerBIEntityNotFound`

The supplied workspace does not contain the **Fabric Capacity Metrics**
semantic model. Find the model in OneLake catalog and rerun the script with its
exact **Workspace** value.

### Analysis server not found

Confirm the workspace name is exact. Then clear the failed permission under
**File** > **Options and settings** > **Data source settings** and sign in
again. The script accepts a workspace display name, not an XMLA endpoint.

### Warehouses are missing

Confirm the signed-in account can access the workspace and query
`queryinsights.exec_requests_history`. Query Insights retains 30 days of
history, excludes system queries, and may take up to 15 minutes to show a
completed query.

## Investigate a capacity spike

1. Select an hour or range with elevated utilization.
2. Filter by Warehouse, artifact kind, status, statement type, or user.
3. Compare query duration, allocated CPU, data scanned, and status.
4. Use **Distributed Statement ID** to correlate Query Insights with Capacity
   Metrics.
5. Review the SQL text and query hash before changing the workload.

## Validate before sharing

- Confirm the Warehouse selector contains only intended Warehouses.
- Confirm selecting a time range filters both capacity and query visuals.
- Confirm `warehouses.configured.csv` contains no unintended endpoints.
- Refresh successfully in Power BI Service before sharing the report.

The package does not deploy objects to customer Warehouses or store reusable
credentials.
