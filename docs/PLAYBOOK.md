# End-to-End Implementation Playbook: Hub/Spoke External API Access from Fabric Spark Notebooks

> **Audience:** Fabric Admins, Data Engineers, and Solution Architects  
> **Last Updated:** May 2026  
> **Estimated Time:** 45–60 minutes

---

## Table of Contents

1. [Overview & Architecture](#1-overview--architecture)
2. [Prerequisites](#2-prerequisites)
3. [Phase 1: Azure Infrastructure Deployment](#3-phase-1-azure-infrastructure-deployment)
4. [Phase 2: Fabric Workspace & Network Configuration](#4-phase-2-fabric-workspace--network-configuration)
5. [Phase 3: Managed Private Endpoint Setup](#5-phase-3-managed-private-endpoint-setup)
6. [Phase 4: Function App Code Deployment](#6-phase-4-function-app-code-deployment)
7. [Phase 5: Fabric Notebook Deployment](#7-phase-5-fabric-notebook-deployment)
8. [Phase 6: End-to-End Validation](#8-phase-6-end-to-end-validation)
9. [Security & Governance Considerations](#9-security--governance-considerations)
10. [Troubleshooting Guide](#10-troubleshooting-guide)
11. [Cost Estimation](#11-cost-estimation)

---

## 1. Overview & Architecture

### Problem Statement

Fabric Spark notebooks operate within a **Managed Virtual Network (VNet)** and cannot directly reach external APIs on the public internet. Organizations need a controlled, auditable, and secure pattern to enable outbound API access while maintaining network isolation.

### Solution: Hub/Spoke with Managed Private Endpoints

This pattern routes all external API calls through a centralized Azure Function App connected to the Fabric workspace via a **Managed Private Endpoint (MPE)**. This provides:

- **Network Isolation** — All traffic flows over private links, never the public internet
- **Centralized Control** — One function app manages all external API integrations
- **Auditability** — All API calls are logged in one place
- **Scalability** — Add new APIs without any infrastructure changes

### Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────────────┐
│                        FABRIC TENANT (Managed VNet)                         │
│                                                                            │
│  ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐         │
│  │  WS_Spoke1      │   │  WS_Spoke2      │   │  WS_SpokeN      │         │
│  │  nb_spoke1_     │   │  nb_spoke2_     │   │  nb_spokeN_     │         │
│  │  zipinfo        │   │  weather        │   │  <your_api>     │         │
│  └────────┬────────┘   └────────┬────────┘   └────────┬────────┘         │
│           │                      │                      │                  │
│           └──────────┐  ┌────────┘  ┌───────────────────┘                  │
│                      ▼  ▼           ▼                                      │
│           ┌──────────────────────────────────┐                             │
│           │  WS_Hub (OAP-enabled workspace)  │                             │
│           │  nb_hub_api_router               │                             │
│           │  (generic API router notebook)   │                             │
│           └──────────────┬───────────────────┘                             │
│                          │                                                 │
│                          │ Managed Private Endpoint                         │
│                          │ (Private Link)                                   │
└──────────────────────────┼─────────────────────────────────────────────────┘
                           │
                           ▼
              ┌──────────────────────────────┐
              │  Azure Function App           │
              │  (App Service Plan - B1)      │
              │                              │
              │  POST /api/CallApi            │
              │  Routes by "api" field:       │
              │    - weather → Open-Meteo     │
              │    - zipinfo → Zippopotam.us  │
              │    - <your_api> → ...         │
              └──────┬──────────┬─────────────┘
                     │          │
                     ▼          ▼
             Zippopotam.us   Open-Meteo
             (city/state)    (weather)
```

### Data Flow

```
1. Spoke Notebook → notebookutils.notebook.run() → Hub Notebook (cross-workspace)
2. Hub Notebook   → requests.post() via MPE     → Azure Function /api/CallApi
3. Azure Function → urllib.request              → External API (internet)
4. Response flows back: External API → Function → Hub → Spoke
```

---

## 2. Prerequisites

### Required Access & Permissions

| Requirement | Details |
|-------------|---------|
| **Azure Subscription** | Owner or Contributor role to create resources |
| **Fabric Capacity** | F2 or higher with Outbound Access Policy (OAP) enabled |
| **Fabric Admin** | Tenant admin access to configure network security policies |
| **Fabric Workspace Admin** | Admin on all workspaces (Hub + Spokes) |
| **Azure CLI** | v2.50+ installed (`az --version`) |

### Tools to Install

```powershell
# Azure CLI
winget install Microsoft.AzureCLI

# (Optional) Azure Functions Core Tools for local testing
npm install -g azure-functions-core-tools@4

# (Optional) GitHub CLI
winget install GitHub.cli
```

### Information to Gather Before Starting

| Item | Example | Where to Find |
|------|---------|---------------|
| Azure Subscription ID | `4c895f15-8113-...` | Azure Portal → Subscriptions |
| Azure Region | `westcentralus` | Choose region close to your Fabric capacity |
| Fabric Workspace ID (Hub) | `1cba541b-8228-...` | Fabric Portal → Workspace → URL |
| Fabric Tenant ID | `1af67986-b784-...` | Azure Portal → Azure AD → Properties |

---

## 3. Phase 1: Azure Infrastructure Deployment

### Step 1.1: Authenticate to Azure

```powershell
# Interactive login (for your Azure tenant)
az login --tenant "<your-tenant>.onmicrosoft.com"

# Set the subscription
az account set --subscription "<subscription-id>"

# Verify
az account show --query "{name:name, id:id, tenantId:tenantId}" -o table
```

### Step 1.2: Create Resource Group

```powershell
$ResourceGroupName = "fabric-hubspoke-rg"
$Location = "westcentralus"  # Match or near your Fabric capacity region

az group create --name $ResourceGroupName --location $Location -o none
```

### Step 1.3: Create Storage Account

The Function App requires a storage account for internal state management.

```powershell
$FunctionAppName = "fn-hubspoke-<unique-suffix>"  # Must be globally unique
$StorageAccountName = "fnhubspoke<suffix>st"       # Lowercase, alphanumeric, max 24 chars

az storage account create `
    --name $StorageAccountName `
    --resource-group $ResourceGroupName `
    --location $Location `
    --sku Standard_LRS `
    --kind StorageV2 `
    --min-tls-version TLS1_2 `
    --allow-blob-public-access false `
    -o none
```

### Step 1.4: Create App Service Plan

```powershell
$PlanName = "$FunctionAppName-plan"

az appservice plan create `
    --name $PlanName `
    --resource-group $ResourceGroupName `
    --location $Location `
    --sku B1 `
    --is-linux `
    -o none
```

> **Note:** B1 (Basic) tier is the minimum for Private Link support. For production, consider S1 or P1v2.

### Step 1.5: Create Function App

```powershell
az functionapp create `
    --name $FunctionAppName `
    --resource-group $ResourceGroupName `
    --plan $PlanName `
    --storage-account $StorageAccountName `
    --runtime python `
    --runtime-version 3.11 `
    --functions-version 4 `
    --os-type Linux `
    -o none
```

### Step 1.6: Configure Identity-Based Storage

Many enterprise tenants enforce `allowSharedKeyAccess=false` via Azure Policy. Configure the function app to use Managed Identity for storage access:

```powershell
# Assign system identity
$PrincipalId = az functionapp identity assign `
    --name $FunctionAppName `
    --resource-group $ResourceGroupName `
    --query principalId -o tsv

$StorageId = az storage account show `
    --name $StorageAccountName `
    --resource-group $ResourceGroupName `
    --query id -o tsv

# Assign required RBAC roles
az role assignment create --assignee $PrincipalId `
    --role "Storage Blob Data Owner" --scope $StorageId -o none
az role assignment create --assignee $PrincipalId `
    --role "Storage Queue Data Contributor" --scope $StorageId -o none
az role assignment create --assignee $PrincipalId `
    --role "Storage Table Data Contributor" --scope $StorageId -o none

# Configure identity-based connection string
az functionapp config appsettings set `
    --name $FunctionAppName `
    --resource-group $ResourceGroupName `
    --settings "AzureWebJobsStorage__accountName=$StorageAccountName" `
    -o none
```

---

## 4. Phase 2: Fabric Workspace & Network Configuration

### Step 2.1: Create Fabric Workspaces

Create three workspaces in the Fabric Portal:

| Workspace Name | Role | Purpose |
|----------------|------|---------|
| `WS_Hub` | Hub | Centralized API router notebook |
| `WS_Spoke1` | Spoke | Zip code info consumer |
| `WS_Spoke2` | Spoke | Weather data consumer |

**Important:** The Hub workspace must be on a **Fabric capacity with OAP (Outbound Access Policy) enabled** to support Managed Private Endpoints.

### Step 2.2: Note Workspace IDs

```powershell
$fabricToken = az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $fabricToken" }

$workspaces = (Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces" -Headers $headers).value
$workspaces | Where-Object { $_.displayName -match "WS_" } | Select-Object displayName, id | Format-Table
```

### Step 2.3: Configure Tenant Network Security — Allowlist the PE Target

> ⚠️ **CRITICAL STEP** — This must be done by a **Fabric Tenant Admin** before creating the Managed Private Endpoint.

The Fabric tenant's network security policy must explicitly allowlist the Azure resource that the Managed Private Endpoint will connect to. Without this, PE creation will fail with `"Private Endpoint not compliant with tenant network setting."`.

```powershell
$fabricToken = az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $fabricToken"; "Content-Type" = "application/json" }

# Define the communication policy
$SubscriptionId = "<your-subscription-id>"
$ResourceGroupName = "fabric-hubspoke-rg"
$FunctionAppName = "fn-hubspoke-<your-suffix>"

$policyBody = @{
    outbound = @{
        managedVirtualNetwork = @{
            privateEndpointTargets = @(
                @{
                    resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
                }
            )
        }
    }
} | ConvertTo-Json -Depth 5

# Apply the policy (POST)
Invoke-RestMethod `
    -Uri "https://api.fabric.microsoft.com/v1/admin/tenant/networksecurity/communicationpolicy" `
    -Method Post `
    -Headers $headers `
    -Body $policyBody
```

**Verify the policy:**

```powershell
$current = Invoke-RestMethod `
    -Uri "https://api.fabric.microsoft.com/v1/admin/tenant/networksecurity/communicationpolicy" `
    -Method Get `
    -Headers $headers
$current | ConvertTo-Json -Depth 5
```

---

## 5. Phase 3: Managed Private Endpoint Setup

### Step 3.1: Create the Managed Private Endpoint

```powershell
$FabricWorkspaceId = "<your-hub-workspace-id>"
$funcResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"

$fabricToken = az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $fabricToken"; "Content-Type" = "application/json" }

$peBody = @{
    name = "funcapp-pe"
    targetPrivateLinkResourceId = $funcResourceId
    targetSubresourceType = "sites"
} | ConvertTo-Json

$peResp = Invoke-RestMethod `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$FabricWorkspaceId/managedPrivateEndpoints" `
    -Method Post `
    -Headers $headers `
    -Body $peBody

$peId = $peResp.id
Write-Host "Created Managed PE: $peId"
```

### Step 3.2: Wait for PE Provisioning

The PE provisioning typically takes 2–3 minutes.

```powershell
$maxWait = 180
$elapsed = 0
while ($elapsed -lt $maxWait) {
    Start-Sleep -Seconds 15
    $elapsed += 15
    
    $fabricToken = az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv
    $headers = @{ Authorization = "Bearer $fabricToken"; "Content-Type" = "application/json" }
    
    $peStatus = Invoke-RestMethod `
        -Uri "https://api.fabric.microsoft.com/v1/workspaces/$FabricWorkspaceId/managedPrivateEndpoints/$peId" `
        -Headers $headers
    
    Write-Host "[$elapsed`s] Provisioning: $($peStatus.provisioningState) | Connection: $($peStatus.connectionState.status)"
    
    if ($peStatus.provisioningState -eq "Succeeded") {
        Write-Host "PE provisioned successfully!"
        break
    }
    if ($peStatus.provisioningState -eq "Failed") {
        throw "PE provisioning failed!"
    }
}
```

### Step 3.3: Approve the Private Endpoint Connection

Once the PE is provisioned, a pending connection request appears on the Function App side. You must approve it.

```powershell
# List PE connections on the Function App
$peConnections = az network private-endpoint-connection list `
    --id "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName" `
    --output json | ConvertFrom-Json

# Find and approve pending connection
$pendingConn = $peConnections | Where-Object {
    $_.properties.privateLinkServiceConnectionState.status -eq "Pending"
} | Select-Object -First 1

if ($pendingConn) {
    az network private-endpoint-connection approve `
        --id $pendingConn.id `
        --description "Approved - demo for customer"
    Write-Host "PE connection approved!"
}
```

### Step 3.4: Verify Final State

```powershell
$fabricToken = az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $fabricToken" }
$finalPE = Invoke-RestMethod `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$FabricWorkspaceId/managedPrivateEndpoints/$peId" `
    -Headers $headers

Write-Host "Provisioning: $($finalPE.provisioningState)"
Write-Host "Connection:   $($finalPE.connectionState.status)"
# Expected: Provisioning=Succeeded | Connection=Approved
```

---

## 6. Phase 4: Function App Code Deployment

### Step 4.1: Prepare the Function Code

The function app is a Python Azure Function with a generic `/api/CallApi` endpoint that routes requests by `api` field.

**Project structure:**
```
function-app/
├── function_app.py       # API router + handlers
├── host.json             # Function host config
└── requirements.txt      # Python dependencies (azure-functions)
```

See [`function-app/function_app.py`](../function-app/function_app.py) for the full source.

### Step 4.2: Deploy via Zip Deploy

```powershell
# Create zip of function code
$zipPath = Join-Path $env:TEMP "funcapp-deploy.zip"
Compress-Archive -Path "function-app\*" -DestinationPath $zipPath -Force

# Deploy
az functionapp deployment source config-zip `
    --name $FunctionAppName `
    --resource-group $ResourceGroupName `
    --src $zipPath `
    -o none

# Wait for cold start
Start-Sleep -Seconds 30
```

### Step 4.3: Verify Deployment

```powershell
# Health check (anonymous endpoint)
$health = Invoke-RestMethod -Uri "https://$FunctionAppName.azurewebsites.net/api/health"
Write-Host "Health: $($health | ConvertTo-Json -Compress)"
# Expected: {"ok":true,"instance_id":"...","supported_apis":["weather","zipinfo"]}
```

### Step 4.4: Retrieve Function Key

```powershell
$funcKey = az functionapp keys list `
    --name $FunctionAppName `
    --resource-group $ResourceGroupName `
    --query "functionKeys.default" -o tsv

Write-Host "Function Key: $funcKey"
```

> **Save this key** — it's needed for the Hub notebook configuration.

---

## 7. Phase 5: Fabric Notebook Deployment

### Step 5.1: Deploy Hub Notebook

The hub notebook is a generic API router with two cells:

1. **Parameters cell** (tagged `parameters`) — receives `api_name`, `params`, `spoke_id`
2. **Logic cell** — calls the Azure Function and returns results

Deploy using the provided script:

```powershell
.\scripts\deploy-notebooks.ps1 `
    -HubWorkspaceId "<WS_Hub GUID>" `
    -Spoke1WorkspaceId "<WS_Spoke1 GUID>" `
    -Spoke2WorkspaceId "<WS_Spoke2 GUID>" `
    -FunctionUrl "https://$FunctionAppName.azurewebsites.net/api/CallApi" `
    -FunctionKey "$funcKey"
```

Or manually create notebooks in Fabric Portal with code from `notebooks/` directory.

### Step 5.2: Configure Cross-Workspace Permissions

For spoke notebooks to call the hub notebook via `notebookutils.notebook.run()`:

1. The spoke workspace identity (or user) must have **Contributor** or higher role on the Hub workspace
2. In Fabric Portal → Hub Workspace → **Manage Access** → Add the spoke workspace identities

---

## 8. Phase 6: End-to-End Validation

### Test 1: Direct Function App Call (Public Endpoint)

```bash
# Health (anonymous)
curl https://fn-hubspoke-8794.azurewebsites.net/api/health

# Weather API
curl -X POST https://fn-hubspoke-8794.azurewebsites.net/api/CallApi \
  -H "Content-Type: application/json" \
  -H "x-functions-key: <key>" \
  -d '{"api":"weather","params":{"zip":"98052"}}'
```

### Test 2: From Fabric Notebook (via MPE)

Open `nb_spoke1_zipinfo` in WS_Spoke1 and run all cells. Expected output:

```
=== WS_Spoke1: Requesting 'zipinfo' API via Hub ===
==================================================
 Zip Code Info Results
==================================================
 Zip Code:   75022
 City:       Flower Mound
 State:      Texas (TX)
 Latitude:   33.0246
 Longitude:  -97.0969
 Country:    US
==================================================
```

### Test 3: Verify Traffic Goes Through MPE

Check the Function App's **Network** tab in Azure Portal — you should see the private endpoint connection active and traffic flowing through it (not the public endpoint).

---

## 9. Security & Governance Considerations

### Network Security

| Control | Implementation |
|---------|---------------|
| **Managed VNet** | All Fabric Spark traffic isolated in managed VNet |
| **Private Link** | Function App accessed only via MPE (private IP) |
| **Tenant allowlist** | Communication policy restricts which resources can be PE targets |
| **Function Key auth** | API calls require `x-functions-key` header |

### Recommendations for Production

1. **Disable public access** on the Function App once MPE is confirmed working:
   ```powershell
   az functionapp config access-restriction add \
       --name $FunctionAppName \
       --resource-group $ResourceGroupName \
       --rule-name "DenyAll" --priority 100 --action Deny \
       --ip-address "0.0.0.0/0"
   ```

2. **Use Azure Key Vault** to store the function key instead of hardcoding in notebooks

3. **Enable Application Insights** for API call monitoring and alerting

4. **Implement rate limiting** in the function app for multi-tenant scenarios

5. **Add AAD authentication** to the Function App for zero-trust scenarios

---

## 10. Troubleshooting Guide

| Error | Cause | Resolution |
|-------|-------|------------|
| `"Private Endpoint not compliant with tenant network setting"` | Fabric tenant communication policy doesn't allowlist the target resource | Run the communication policy POST (Phase 2, Step 2.3) |
| `"EntityNotFound"` when listing/creating PEs | Wrong workspace ID or workspace not on OAP-enabled capacity | Verify workspace ID and that the capacity has OAP enabled |
| Function health returns 404 | Code not yet deployed or cold-start not complete | Wait 30-60s after deployment; verify via `az functionapp show` that state is "Running" |
| `"ResourceGroupNotFound"` | Logged into wrong tenant/subscription | Run `az account show` and verify correct context |
| Function key list returns "Bad Request" | Function host not yet initialized after deploy | Wait 60s and retry; check deployment logs |
| Spoke notebook fails with `run() got unexpected keyword argument` | Wrong parameter format for `notebookutils.notebook.run()` | Use positional args: `run(name, timeout, args_dict, workspace_id)` |
| PE stuck in "Provisioning" state | Normal — provisioning takes 2-3 minutes | Wait up to 5 minutes; check Fabric Portal for status |
| PE connection shows "Pending" | Connection not yet approved on Azure side | Run `az network private-endpoint-connection approve` (Phase 3, Step 3.3) |

---

## 11. Cost Estimation

| Resource | SKU | Estimated Monthly Cost |
|----------|-----|----------------------|
| App Service Plan | B1 (Linux) | ~$13/month |
| Storage Account | Standard LRS | ~$1/month |
| Function App | Included in plan | $0 |
| Fabric Capacity (F2) | F2 | Depends on existing capacity |
| **Total Azure cost** | | **~$14/month** |

> **Note:** For production workloads with higher throughput, upgrade to S1 ($73/month) or P1v2 ($145/month).

---

## Quick Reference: Full Automated Deployment

For a single-script deployment covering all phases, use:

```powershell
.\scripts\deploy-fabric-oap-funcapp.ps1 `
    -SubscriptionId "<sub-id>" `
    -FabricWorkspaceId "<workspace-id>" `
    -Location "westcentralus" `
    -ResourceGroupName "fabric-hubspoke-rg"
```

This script automates all steps from Phase 1 through Phase 3 (infrastructure + MPE creation + approval).

---

## Appendix: API Reference

### Fabric Admin API — Communication Policy

```
POST https://api.fabric.microsoft.com/v1/admin/tenant/networksecurity/communicationpolicy
GET  https://api.fabric.microsoft.com/v1/admin/tenant/networksecurity/communicationpolicy
```

### Fabric Workspace API — Managed Private Endpoints

```
GET    https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/managedPrivateEndpoints
POST   https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/managedPrivateEndpoints
GET    https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/managedPrivateEndpoints/{peId}
DELETE https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/managedPrivateEndpoints/{peId}
```

### Azure CLI — Private Endpoint Connections

```powershell
az network private-endpoint-connection list --id "<resource-id>"
az network private-endpoint-connection approve --id "<connection-id>" --description "<justification>"
```
