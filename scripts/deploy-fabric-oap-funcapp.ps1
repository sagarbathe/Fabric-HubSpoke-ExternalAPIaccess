<#
.SYNOPSIS
    Deploy an Azure Function App and configure Managed Private Endpoint from a Fabric OAP workspace.

.DESCRIPTION
    This script:
    1. Logs into Azure (supports certificate-based SPN or interactive)
    2. Creates resource group, storage account, app service plan, and function app
    3. Deploys the function app code (weather/zipinfo API router)
    4. Creates a managed private endpoint from a Fabric workspace to the function app
    5. Approves the PE connection on the function app side
    6. Verifies end-to-end connectivity

.PARAMETER TenantId
    Azure AD tenant ID (extracted from login user if not specified)

.PARAMETER SubscriptionId
    Azure subscription ID to deploy resources into

.PARAMETER Location
    Azure region for resources (default: westcentralus)

.PARAMETER ResourceGroupName
    Name for the resource group (default: fabric-oap-funcapp-rg)

.PARAMETER FunctionAppName
    Name for the function app (default: auto-generated with random suffix)

.PARAMETER FabricWorkspaceId
    The Fabric workspace ID (GUID) with OAP enabled where the managed PE will be created

.PARAMETER CertificatePath
    Path to PFX certificate for SPN login (optional, uses interactive login if not provided)

.PARAMETER CertificateUser
    User/SPN to login with certificate (optional)

.EXAMPLE
    # Interactive login
    .\deploy-fabric-oap-funcapp.ps1 -SubscriptionId "your-sub-id" -FabricWorkspaceId "your-workspace-id"

.EXAMPLE
    # Certificate-based login
    .\deploy-fabric-oap-funcapp.ps1 `
        -SubscriptionId "your-sub-id" `
        -FabricWorkspaceId "your-workspace-id" `
        -CertificatePath "C:\path\to\cert.pfx" `
        -CertificateUser "admin@yourtenant.onmicrosoft.com"
#>

param(
    [string]$TenantId = "",
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,
    [string]$Location = "westcentralus",
    [string]$ResourceGroupName = "fabric-oap-funcapp-rg",
    [string]$FunctionAppName = "",
    [Parameter(Mandatory=$true)]
    [string]$FabricWorkspaceId,
    [string]$CertificatePath = "",
    [string]$CertificateUser = "",
    [string]$ManagedPEName = "funcapp-pe"
)

$ErrorActionPreference = "Stop"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Step { param([string]$msg) Write-Host "`n$('='*70)" -ForegroundColor Cyan; Write-Host "  $msg" -ForegroundColor Cyan; Write-Host "$('='*70)" -ForegroundColor Cyan }
function Write-OK { param([string]$msg) Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Info { param([string]$msg) Write-Host "  [INFO] $msg" -ForegroundColor Yellow }

# ============================================================================
# STEP 1: AUTHENTICATION
# ============================================================================

Write-Step "Step 1: Azure Authentication"

if ($CertificatePath -and $CertificateUser) {
    Write-Info "Logging in with certificate: $CertificateUser"
    # Extract tenant from user domain
    if (-not $TenantId) {
        $domain = $CertificateUser.Split('@')[1]
        Write-Info "Using domain as tenant: $domain"
        az login --service-principal -u $CertificateUser -p $CertificatePath --tenant $domain --only-show-errors | Out-Null
    } else {
        az login --service-principal -u $CertificateUser -p $CertificatePath --tenant $TenantId --only-show-errors | Out-Null
    }
} else {
    Write-Info "Using interactive login (or existing session)"
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) {
        az login --only-show-errors | Out-Null
    }
}

az account set --subscription $SubscriptionId
$account = az account show | ConvertFrom-Json
Write-OK "Logged in as: $($account.user.name) | Subscription: $($account.name)"
if (-not $TenantId) { $TenantId = $account.tenantId }

# ============================================================================
# STEP 2: CREATE RESOURCE GROUP
# ============================================================================

Write-Step "Step 2: Create Resource Group"

$rgExists = az group exists --name $ResourceGroupName
if ($rgExists -eq "true") {
    Write-Info "Resource group '$ResourceGroupName' already exists"
} else {
    az group create --name $ResourceGroupName --location $Location --only-show-errors -o none
    Write-OK "Created resource group: $ResourceGroupName ($Location)"
}

# ============================================================================
# STEP 3: CREATE STORAGE ACCOUNT (for Function App)
# ============================================================================

Write-Step "Step 3: Create Storage Account for Function App"

if (-not $FunctionAppName) {
    $suffix = Get-Random -Minimum 1000 -Maximum 9999
    $FunctionAppName = "fn-hubspoke-$suffix"
}
$storageAccountName = ($FunctionAppName -replace '[^a-z0-9]','').Substring(0, [Math]::Min(20, ($FunctionAppName -replace '[^a-z0-9]','').Length)) + "st"

Write-Info "Function App Name: $FunctionAppName"
Write-Info "Storage Account Name: $storageAccountName"

$storageExists = az storage account show --name $storageAccountName --resource-group $ResourceGroupName 2>$null
if (-not $storageExists) {
    az storage account create `
        --name $storageAccountName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --sku Standard_LRS `
        --kind StorageV2 `
        --min-tls-version TLS1_2 `
        --allow-blob-public-access false `
        --only-show-errors -o none
    Write-OK "Created storage account: $storageAccountName"
} else {
    Write-Info "Storage account '$storageAccountName' already exists"
}

# ============================================================================
# STEP 4: CREATE APP SERVICE PLAN + FUNCTION APP
# ============================================================================

Write-Step "Step 4: Create App Service Plan and Function App"

$planName = "$FunctionAppName-plan"

$planExists = az appservice plan show --name $planName --resource-group $ResourceGroupName 2>$null
if (-not $planExists) {
    az appservice plan create `
        --name $planName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --sku B1 `
        --is-linux `
        --only-show-errors -o none
    Write-OK "Created App Service Plan: $planName (Linux B1)"
} else {
    Write-Info "App Service Plan '$planName' already exists"
}

$funcExists = az functionapp show --name $FunctionAppName --resource-group $ResourceGroupName 2>$null
if (-not $funcExists) {
    az functionapp create `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName `
        --plan $planName `
        --storage-account $storageAccountName `
        --runtime python `
        --runtime-version 3.11 `
        --functions-version 4 `
        --os-type Linux `
        --only-show-errors -o none
    Write-OK "Created Function App: $FunctionAppName"
    
    # Configure identity-based storage connection (avoid shared key issues)
    Write-Info "Configuring identity-based storage connection..."
    $funcIdentity = az functionapp identity assign --name $FunctionAppName --resource-group $ResourceGroupName --query principalId -o tsv
    $storageId = az storage account show --name $storageAccountName --resource-group $ResourceGroupName --query id -o tsv
    
    az role assignment create --assignee $funcIdentity --role "Storage Blob Data Owner" --scope $storageId --only-show-errors -o none 2>$null
    az role assignment create --assignee $funcIdentity --role "Storage Queue Data Contributor" --scope $storageId --only-show-errors -o none 2>$null
    az role assignment create --assignee $funcIdentity --role "Storage Table Data Contributor" --scope $storageId --only-show-errors -o none 2>$null
    
    $storageConnStr = "https://$storageAccountName.blob.core.windows.net"
    az functionapp config appsettings set --name $FunctionAppName --resource-group $ResourceGroupName `
        --settings "AzureWebJobsStorage__accountName=$storageAccountName" `
        --only-show-errors -o none
    
    Write-OK "Configured identity-based storage connection"
} else {
    Write-Info "Function App '$FunctionAppName' already exists"
}

# ============================================================================
# STEP 5: DEPLOY FUNCTION APP CODE
# ============================================================================

Write-Step "Step 5: Deploy Function App Code"

$deployDir = Join-Path $env:TEMP "funcapp-deploy-$(Get-Random)"
New-Item -ItemType Directory -Path $deployDir -Force | Out-Null

# function_app.py
@'
import json
import logging
import os
import uuid
import urllib.request
import urllib.error
from datetime import datetime, timezone

import azure.functions as func

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

_INSTANCE_ID = uuid.uuid4().hex[:8]

# Zip-to-coordinates mapping for weather
ZIP_COORDS = {
    "75022": {"lat": 33.0246, "lon": -97.0969, "city": "Flower Mound, TX"},
    "10001": {"lat": 40.7484, "lon": -73.9967, "city": "New York, NY"},
    "90210": {"lat": 34.0901, "lon": -118.4065, "city": "Beverly Hills, CA"},
    "98052": {"lat": 47.6740, "lon": -122.1215, "city": "Redmond, WA"},
    "94105": {"lat": 37.7898, "lon": -122.3942, "city": "San Francisco, CA"},
}

WEATHER_API_URL = (
    "https://api.open-meteo.com/v1/forecast"
    "?latitude={lat}&longitude={lon}"
    "&current=temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code"
    "&temperature_unit=fahrenheit&wind_speed_unit=mph"
)


def _handle_weather(params: dict) -> dict:
    """Fetch current weather from Open-Meteo (free, no key)."""
    zip_code = params.get("zip", "75022")
    coords = ZIP_COORDS.get(zip_code)
    if not coords:
        return {"ok": False, "error": f"Unknown zip code: {zip_code}"}
    url = WEATHER_API_URL.format(lat=coords["lat"], lon=coords["lon"])
    with urllib.request.urlopen(url, timeout=10) as resp:
        data = json.loads(resp.read().decode())
    current = data.get("current", {})
    return {
        "ok": True, "api": "weather", "zip": zip_code, "city": coords["city"],
        "current": {
            "temperature_f": current.get("temperature_2m"),
            "humidity_pct": current.get("relative_humidity_2m"),
            "wind_speed_mph": current.get("wind_speed_10m"),
            "weather_code": current.get("weather_code"),
        },
    }


def _handle_zipinfo(params: dict) -> dict:
    """Lookup city/state for a US zip code via Zippopotam.us (free, no key)."""
    zip_code = params.get("zip", "75022")
    url = f"https://api.zippopotam.us/us/{zip_code}"
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": f"Zip lookup failed ({e.code}): {zip_code}"}
    places = data.get("places", [])
    place = places[0] if places else {}
    return {
        "ok": True, "api": "zipinfo", "zip": zip_code,
        "city": place.get("place name", ""), "state": place.get("state", ""),
        "state_abbr": place.get("state abbreviation", ""),
        "latitude": place.get("latitude", ""), "longitude": place.get("longitude", ""),
        "country": data.get("country", ""),
    }


API_HANDLERS = {"weather": _handle_weather, "zipinfo": _handle_zipinfo}


@app.function_name(name="CallApi")
@app.route(route="CallApi", methods=["GET", "POST"])
def call_api(req: func.HttpRequest) -> func.HttpResponse:
    """Generic API router: { "api": "weather"|"zipinfo", "params": { ... } }"""
    logging.info("CallApi invoked (instance=%s)", _INSTANCE_ID)
    body = {}
    try:
        body = req.get_json() or {}
    except ValueError:
        pass
    api_name = body.get("api") or req.params.get("api") or ""
    params = body.get("params", {})
    if not api_name:
        return func.HttpResponse(json.dumps({"ok": False, "error": "Missing 'api' field. Supported: " + ", ".join(API_HANDLERS.keys())}), status_code=400, mimetype="application/json")
    handler = API_HANDLERS.get(api_name)
    if not handler:
        return func.HttpResponse(json.dumps({"ok": False, "error": f"Unknown api '{api_name}'. Supported: " + ", ".join(API_HANDLERS.keys())}), status_code=400, mimetype="application/json")
    try:
        result = handler(params)
        result["fetched_at"] = datetime.now(timezone.utc).isoformat()
        result["instance_id"] = _INSTANCE_ID
        result["function_app"] = os.environ.get("WEBSITE_SITE_NAME", "local")
    except Exception as exc:
        logging.error("API handler '%s' error: %s", api_name, exc)
        result = {"ok": False, "error": str(exc), "api": api_name, "fetched_at": datetime.now(timezone.utc).isoformat(), "instance_id": _INSTANCE_ID}
    return func.HttpResponse(json.dumps(result), status_code=200 if result.get("ok") else 502, mimetype="application/json")


@app.function_name(name="Health")
@app.route(route="health", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def health(req: func.HttpRequest) -> func.HttpResponse:
    return func.HttpResponse(json.dumps({"ok": True, "instance_id": _INSTANCE_ID, "supported_apis": list(API_HANDLERS.keys())}), status_code=200, mimetype="application/json")
'@ | Set-Content -Path (Join-Path $deployDir "function_app.py") -Encoding utf8

# host.json
@'
{
  "version": "2.0",
  "logging": {
    "applicationInsights": {
      "samplingSettings": { "isEnabled": true, "excludedTypes": "Request" }
    }
  },
  "extensionBundle": {
    "id": "Microsoft.Azure.Functions.ExtensionBundle",
    "version": "[4.*, 5.0.0)"
  }
}
'@ | Set-Content -Path (Join-Path $deployDir "host.json") -Encoding utf8

# requirements.txt
"azure-functions" | Set-Content -Path (Join-Path $deployDir "requirements.txt") -Encoding utf8

# Deploy via zip
Write-Info "Creating deployment zip..."
$zipPath = Join-Path $env:TEMP "funcapp-deploy.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath }
Compress-Archive -Path (Join-Path $deployDir "*") -DestinationPath $zipPath

Write-Info "Deploying to Azure..."
az functionapp deployment source config-zip `
    --name $FunctionAppName `
    --resource-group $ResourceGroupName `
    --src $zipPath `
    --only-show-errors -o none

# Wait for cold start
Write-Info "Waiting for function app to warm up (30s)..."
Start-Sleep -Seconds 30

# Verify health
$funcUrl = "https://$FunctionAppName.azurewebsites.net"
try {
    $healthResp = Invoke-RestMethod -Uri "$funcUrl/api/health" -TimeoutSec 30
    if ($healthResp.ok) {
        Write-OK "Function App is healthy: $funcUrl"
    }
} catch {
    Write-Info "Health check failed (may need more warmup time): $_"
}

# Get function key
$funcKey = az functionapp keys list --name $FunctionAppName --resource-group $ResourceGroupName --query "functionKeys.default" -o tsv
Write-OK "Function Key: $funcKey"

# Cleanup temp
Remove-Item -Path $deployDir -Recurse -Force
Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue

# ============================================================================
# STEP 6: CREATE MANAGED PRIVATE ENDPOINT IN FABRIC WORKSPACE
# ============================================================================

Write-Step "Step 6: Create Managed Private Endpoint in Fabric Workspace"

$funcResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
Write-Info "Function App Resource ID: $funcResourceId"
Write-Info "Fabric Workspace ID: $FabricWorkspaceId"

# Get Fabric token
$fabricToken = az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv
$fabricHeaders = @{ Authorization = "Bearer $fabricToken"; "Content-Type" = "application/json" }

# Check if PE already exists
$existingPEs = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces/$FabricWorkspaceId/managedPrivateEndpoints" -Headers $fabricHeaders
$existingFuncPE = $existingPEs.value | Where-Object { $_.name -eq $ManagedPEName }

if ($existingFuncPE) {
    Write-Info "Managed PE '$ManagedPEName' already exists (state: $($existingFuncPE.provisioningState), connection: $($existingFuncPE.connectionState.status))"
    $peId = $existingFuncPE.id
} else {
    $peBody = @{
        name = $ManagedPEName
        targetPrivateLinkResourceId = $funcResourceId
        targetSubresourceType = "sites"
    } | ConvertTo-Json

    $peResp = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces/$FabricWorkspaceId/managedPrivateEndpoints" -Method Post -Headers $fabricHeaders -Body $peBody
    $peId = $peResp.id
    Write-OK "Created Managed PE: $peId (provisioning...)"
}

# ============================================================================
# STEP 7: WAIT FOR PE PROVISIONING & APPROVE
# ============================================================================

Write-Step "Step 7: Wait for PE Provisioning and Approve"

$maxWait = 180
$elapsed = 0
while ($elapsed -lt $maxWait) {
    Start-Sleep -Seconds 15
    $elapsed += 15
    
    # Refresh token if needed
    $fabricToken = az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv
    $fabricHeaders = @{ Authorization = "Bearer $fabricToken"; "Content-Type" = "application/json" }
    
    $peStatus = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces/$FabricWorkspaceId/managedPrivateEndpoints/$peId" -Headers $fabricHeaders
    Write-Info "[$elapsed`s] Provisioning: $($peStatus.provisioningState) | Connection: $($peStatus.connectionState.status)"
    
    if ($peStatus.provisioningState -eq "Succeeded") {
        Write-OK "PE provisioned successfully"
        break
    }
    if ($peStatus.provisioningState -eq "Failed") {
        Write-Host "  [ERROR] PE provisioning failed!" -ForegroundColor Red
        $peStatus | ConvertTo-Json -Depth 5
        exit 1
    }
}

# Approve the PE connection on the function app side
Write-Info "Looking for pending PE connection on function app..."
Start-Sleep -Seconds 10

$peConnections = az network private-endpoint-connection list `
    --id "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName" `
    --output json 2>$null | ConvertFrom-Json

$pendingConn = $peConnections | Where-Object { $_.properties.privateLinkServiceConnectionState.status -eq "Pending" } | Select-Object -First 1

if ($pendingConn) {
    Write-Info "Approving PE connection: $($pendingConn.name)"
    az network private-endpoint-connection approve `
        --id $pendingConn.id `
        --description "Approved by deployment script" `
        --only-show-errors -o none
    Write-OK "PE connection approved!"
} else {
    $approvedConn = $peConnections | Where-Object { $_.properties.privateLinkServiceConnectionState.status -eq "Approved" }
    if ($approvedConn) {
        Write-Info "PE connection already approved"
    } else {
        Write-Host "  [WARN] No PE connection found - may need manual approval" -ForegroundColor Yellow
    }
}

# Verify final state
Start-Sleep -Seconds 5
$fabricToken = az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv
$fabricHeaders = @{ Authorization = "Bearer $fabricToken" }
$finalPE = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces/$FabricWorkspaceId/managedPrivateEndpoints/$peId" -Headers $fabricHeaders
Write-OK "Final PE State: Provisioning=$($finalPE.provisioningState) | Connection=$($finalPE.connectionState.status)"

# ============================================================================
# STEP 8: OUTPUT SUMMARY & NOTEBOOK CODE
# ============================================================================

Write-Step "DEPLOYMENT COMPLETE - Summary"

Write-Host @"

  Function App URL:  https://$FunctionAppName.azurewebsites.net
  Function Key:      $funcKey
  Resource Group:    $ResourceGroupName
  Subscription:      $SubscriptionId
  Fabric Workspace:  $FabricWorkspaceId
  Managed PE Name:   $ManagedPEName
  Managed PE ID:     $peId
  PE Status:         $($finalPE.connectionState.status)

"@ -ForegroundColor White

Write-Step "Notebook Test Code (copy into Fabric Notebook)"

Write-Host @"

# --- Paste this into a Fabric Notebook cell in workspace $FabricWorkspaceId ---

import requests, json

FUNC_URL = "https://$FunctionAppName.azurewebsites.net"
FUNC_KEY = "$funcKey"

# Test 1: Health (anonymous)
print("TEST 1: Health endpoint")
resp = requests.get(f"{FUNC_URL}/api/health", timeout=30)
print(f"  Status: {resp.status_code} | Response: {resp.json()}")

# Test 2: CallApi Weather
print("\nTEST 2: CallApi Weather (Redmond, WA)")
resp = requests.post(
    f"{FUNC_URL}/api/CallApi",
    json={"api": "weather", "params": {"zip": "98052"}},
    headers={"x-functions-key": FUNC_KEY},
    timeout=30
)
print(f"  Status: {resp.status_code} | Response: {resp.json()}")

# Test 3: CallApi ZipInfo
print("\nTEST 3: CallApi ZipInfo (NYC)")
resp = requests.post(
    f"{FUNC_URL}/api/CallApi",
    json={"api": "zipinfo", "params": {"zip": "10001"}},
    headers={"x-functions-key": FUNC_KEY},
    timeout=30
)
print(f"  Status: {resp.status_code} | Response: {resp.json()}")

"@ -ForegroundColor Gray

Write-Host "`nDone! Run the notebook code above to verify connectivity from the OAP workspace." -ForegroundColor Green
