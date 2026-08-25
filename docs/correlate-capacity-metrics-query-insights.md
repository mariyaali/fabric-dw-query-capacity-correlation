---
title: Correlate Fabric capacity metrics with Warehouse query insights
description: Configure a Power BI report that correlates Microsoft Fabric capacity utilization with Query Insights from customer-owned Warehouses.
author: mariyaali
ms.author: mariyaali
ms.reviewer: wiassaf
ms.service: fabric
ms.subservice: data-warehouse
ms.topic: how-to
ms.date: 06/13/2026
---

# Correlate Fabric capacity metrics with Warehouse query insights

[!INCLUDE [applies-to-version](includes/applies-to-version/fabric-dw.md)]

This article shows how to configure a Power BI Desktop project that places
Microsoft Fabric capacity utilization and Warehouse Query Insights on the same
time axis. Use the report to identify the customer-owned Warehouse statements
that were active during a capacity spike and then investigate their duration,
CPU time, scan volume, status, and command text.

The project reads data from the Microsoft Fabric Capacity Metrics semantic
model and from `queryinsights.exec_requests_history` in each configured
Warehouse. It doesn't deploy views, procedures, or other objects to a
Warehouse.

## Prerequisites

Before you begin, make sure you have:

- Power BI Desktop with Power BI project (PBIP) support.
- Windows PowerShell 5.1 or PowerShell 7.
- Read access to the workspace and semantic model created by the Microsoft
  Fabric Capacity Metrics app.
- Contributor or higher permissions on each Warehouse that you include.
- The SQL endpoint host name and item ID for each Warehouse, or Fabric
  administrator access for automatic discovery.
- Azure CLI authentication if you use automatic capacity discovery.

## Get the Capacity Metrics connection

1. Open the workspace that contains the **Fabric Capacity Metrics** semantic
   model.
2. Open **Workspace settings**.
3. Under **Premium**, copy **Workspace connection**.
4. Confirm that the value starts with:

   ```text
   powerbi://api.powerbi.com/v1.0/myorg/
   ```

The workspace portion of an XMLA endpoint is URL-encoded. For example, spaces
appear as `%20`. Don't append the semantic-model name to the server value.

## Configure selected Warehouses

Use a CSV when you want to include a controlled list of Warehouses.

1. Clone the sample repository and open PowerShell in its root folder.
2. Copy the example inventory:

   ```powershell
   Copy-Item .\warehouses.example.csv .\warehouses.csv
   ```

3. Replace every `REPLACE-WITH-...` value with customer-owned resource
   information. Use only the SQL endpoint host name, without `https://` or a
   database suffix.
4. Run the configuration:

   ```powershell
   .\Configure-CustomerTemplate.ps1 `
     -CapacityMetricsEndpoint "powerbi://api.powerbi.com/v1.0/myorg/Capacity%20Metrics%20Workspace" `
     -WarehouseConfigPath ".\warehouses.csv"
   ```

The script writes a new `Configured` folder. Review
`warehouses.configured.csv` and `connection-settings.json` before you open the
project.

## Discover Warehouses on a capacity

Use automatic discovery when the signed-in identity can enumerate the required
workspaces and Warehouses.

1. Sign in to Azure CLI:

   ```azurecli
   az login
   az account show
   ```

2. Confirm that the active account is in the tenant that owns the Fabric
   resources.
3. Run the configuration with the Fabric capacity ID:

   ```powershell
   .\Configure-CustomerTemplate.ps1 `
     -CapacityMetricsEndpoint "powerbi://api.powerbi.com/v1.0/myorg/Capacity%20Metrics%20Workspace" `
     -CapacityId "00000000-0000-0000-0000-000000000000"
   ```

The script tries the Fabric Admin API first. If the identity doesn't have
tenant-wide read permission, the script falls back to workspaces that the
identity can access. A Warehouse is included only when the identity can list
the item and retrieve its SQL connection information.

## Open and refresh the report

1. Open `Configured\Query Capacity Correlation.pbip` in Power BI Desktop.
2. Compare the Capacity Metrics server and semantic-model name in the sign-in
   prompt with `Configured\connection-settings.json`.
3. Sign in with an organizational account in the resource tenant.
4. Sign in to each Warehouse SQL endpoint.
5. Set all data-source privacy levels to **Organizational**.
6. Review and approve the native Query Insights SQL prompt for each endpoint.
7. Refresh the semantic model.

Power BI Desktop stores credentials separately from the PBIP source files. The
configured project contains resource names, item IDs, and endpoints, but no
reusable credentials.

## Investigate a capacity spike

1. On **Capacity and Query Overview**, select an hour or time range with
   elevated capacity utilization.
2. Filter by Warehouse, artifact kind, query status, statement type, or user.
3. Review the queries that overlapped the selected time range. A long-running
   statement can appear in more than one hourly window, but report measures
   count its execution once.
4. Open **Query Investigation**.
5. Compare query duration, allocated CPU time, scan volume, result-cache use,
   and status.
6. Use **Distributed Statement ID** to correlate the Query Insights row with
   the corresponding Capacity Metrics operation.
7. Review command text and query hash before you tune or reschedule a workload.

Query Insights contains user queries, not system queries. Completed queries can
take up to 15 minutes to appear, and Query Insights retains historic data for
30 days.

Capacity Metrics distinguishes interactive and background operations. Use the
operation and billing classifications supplied by Capacity Metrics. Don't
infer billing status from a query's duration, front-end activity, or whether it
has a distributed statement ID.

## Publish and configure refresh

1. Publish the report and semantic model from Power BI Desktop to a
   customer-owned workspace.
2. Open the semantic-model settings in the Fabric portal.
3. Under **Gateway and cloud connections**, map every Warehouse SQL source and
   the Capacity Metrics source to customer-owned connections.
4. Run an on-demand refresh.
5. Confirm that the refresh succeeds before you share the report.

Desktop credentials aren't transferred to the Fabric service. An OAuth or
credentials error after publishing means that at least one cloud connection
still requires configuration.

## Troubleshoot the connection

### Analysis server name isn't valid

- Confirm that the server starts with
  `powerbi://api.powerbi.com/v1.0/myorg/`.
- Copy the workspace connection from the workspace that contains the Capacity
  Metrics semantic model.
- Pass the full server with `-CapacityMetricsEndpoint`.
- Confirm that the semantic-model display name is **Fabric Capacity Metrics**,
  or supply the actual name with `-CapacityMetricsModel`.
- Clear the failed Capacity Metrics permission in **File** > **Options and
  settings** > **Data source settings**, and then sign in again.

### Sign-in uses the wrong tenant or an expired permission

Clear the affected data-source permission in Power BI Desktop and authenticate
again with an account in the tenant that owns the resources. Azure CLI is
required only for automatic discovery; CSV-based setup doesn't require an
Azure subscription.

### Queries don't appear

Confirm that the account can query
`queryinsights.exec_requests_history` in each Warehouse. Allow for Query
Insights processing latency and verify that the query completed within the
30-day retention window.

## Related content

- [What is the Microsoft Fabric Capacity Metrics app?](../enterprise/metrics-app.md)
- [Install the Microsoft Fabric Capacity Metrics app](../enterprise/metrics-app-install.md)
- [Query Insights](query-insights.md)
- [Semantic model connectivity with the XMLA endpoint](../enterprise/powerbi/service-premium-connect-tools.md)
- [Power BI Desktop projects](https://learn.microsoft.com/power-bi/developer/projects/projects-overview)
