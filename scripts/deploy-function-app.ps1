<#
.SYNOPSIS
    Deploys the Azure Function App for the Hub/Spoke external API access pattern.

.DESCRIPTION
    Creates an Azure Resource Group, Storage Account, App Service Plan, and Function App.
    Deploys the function code and outputs the Function URL and key.

.PARAMETER ResourceGroupName
    Name of the Azure Resource Group (default: fabric-hubspoke-rg)

.PARAMETER Location
    Azure region (default: westus3)

.PARAMETER FunctionAppName
    Name for the Function App - must be globally unique (default: auto-generated)
#>

param(
    [string]$ResourceGroupName = "fabric-hubspoke-rg",
    [string]$Location = "westus3",
    [string]$FunctionAppName = ""
)

$ErrorActionPreference = "Stop"

# Generate unique names if not provided
$rand = Get-Random -Minimum 1000 -Maximum 9999
if (-not $FunctionAppName) { $FunctionAppName = "fn-hubspoke-$rand" }
$storageName = "fnhubspoke$rand"
$planName = "$FunctionAppName-plan"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Deploying Hub/Spoke Azure Function App" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Resource Group:   $ResourceGroupName"
Write-Host "Location:         $Location"
Write-Host "Function App:     $FunctionAppName"
Write-Host "Storage Account:  $storageName"
Write-Host "App Service Plan: $planName"
Write-Host ""

# 1. Create Resource Group
Write-Host "[1/6] Creating Resource Group..." -ForegroundColor Yellow
az group create -n $ResourceGroupName -l $Location --only-show-errors -o none

# 2. Create Storage Account
Write-Host "[2/6] Creating Storage Account..." -ForegroundColor Yellow
az storage account create -n $storageName -g $ResourceGroupName -l $Location --sku Standard_LRS --only-show-errors -o none

# 3. Create App Service Plan (Linux B1)
Write-Host "[3/6] Creating App Service Plan (Linux B1)..." -ForegroundColor Yellow
az appservice plan create -n $planName -g $ResourceGroupName -l $Location --sku B1 --is-linux --only-show-errors -o none

# 4. Create Function App
Write-Host "[4/6] Creating Function App..." -ForegroundColor Yellow
az functionapp create -n $FunctionAppName -g $ResourceGroupName `
    --plan $planName --storage-account $storageName `
    --runtime python --runtime-version 3.11 --functions-version 4 `
    --os-type Linux --assign-identity "[system]" --only-show-errors -o none

# 5. Configure identity-based storage (for tenants with shared key disabled)
Write-Host "[5/6] Configuring identity-based storage..." -ForegroundColor Yellow
$principalId = az functionapp identity show -n $FunctionAppName -g $ResourceGroupName --query principalId -o tsv --only-show-errors
$storageId = az storage account show -n $storageName -g $ResourceGroupName --query id -o tsv --only-show-errors

# Assign storage roles
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Storage Blob Data Owner" --scope $storageId --only-show-errors -o none
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Storage Account Contributor" --scope $storageId --only-show-errors -o none
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Storage Queue Data Contributor" --scope $storageId --only-show-errors -o none
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Storage Table Data Contributor" --scope $storageId --only-show-errors -o none

# Configure app settings for identity-based storage
az functionapp config appsettings set -n $FunctionAppName -g $ResourceGroupName --settings `
    "AzureWebJobsStorage__accountName=$storageName" `
    "AzureWebJobsStorage__blobServiceUri=https://$storageName.blob.core.windows.net" `
    "AzureWebJobsStorage__queueServiceUri=https://$storageName.queue.core.windows.net" `
    "AzureWebJobsStorage__tableServiceUri=https://$storageName.table.core.windows.net" `
    "AzureWebJobsFeatureFlags=EnableWorkerIndexing" `
    "SCM_DO_BUILD_DURING_DEPLOYMENT=true" `
    "ENABLE_ORYX_BUILD=true" `
    --only-show-errors -o none

# Enable SCM basic auth for deployment
$subscriptionId = az account show --query id -o tsv --only-show-errors
$scmUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/basicPublishingCredentialsPolicies/scm?api-version=2023-12-01"
$policyBody = '{"properties":{"allow":true}}'
$policyFile = [System.IO.Path]::GetTempFileName()
$policyBody | Out-File -FilePath $policyFile -Encoding utf8
az rest --method PUT --uri $scmUri --body "@$policyFile" --headers "Content-Type=application/json" --only-show-errors -o none
Remove-Item $policyFile -Force

# 6. Deploy the function code
Write-Host "[6/6] Deploying function code..." -ForegroundColor Yellow
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$functionDir = Join-Path $scriptDir "..\function-app"
$zipPath = Join-Path $env:TEMP "hubspoke-function.zip"
Compress-Archive -Path "$functionDir\function_app.py", "$functionDir\host.json", "$functionDir\requirements.txt" -DestinationPath $zipPath -Force

$creds = az webapp deployment list-publishing-credentials -n $FunctionAppName -g $ResourceGroupName --only-show-errors -o json | ConvertFrom-Json
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($creds.publishingUserName):$($creds.publishingPassword)"))

Start-Sleep -Seconds 10  # Wait for app to be ready
$deployResult = curl -s -X POST "https://$FunctionAppName.scm.azurewebsites.net/api/zipdeploy" `
    -H "Authorization: Basic $base64Auth" `
    -H "Content-Type: application/zip" `
    --data-binary "@$zipPath" `
    -w "%{http_code}"

Remove-Item $zipPath -Force

if ($deployResult -match "200") {
    Write-Host "`nDeployment successful!" -ForegroundColor Green
} else {
    Write-Host "`nDeployment returned: $deployResult" -ForegroundColor Red
    exit 1
}

# Wait and get function key
Write-Host "`nWaiting for function host to initialize..." -ForegroundColor Yellow
Start-Sleep -Seconds 20

$keysUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/host/default/listkeys?api-version=2023-12-01"
$keys = az rest --method POST --uri $keysUri --only-show-errors -o json 2>$null | ConvertFrom-Json
$functionKey = $keys.functionKeys.default

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Function App URL: https://$FunctionAppName.azurewebsites.net" -ForegroundColor White
Write-Host "CallApi Endpoint: https://$FunctionAppName.azurewebsites.net/api/CallApi" -ForegroundColor White
Write-Host "Health Endpoint:  https://$FunctionAppName.azurewebsites.net/api/health" -ForegroundColor White
Write-Host ""
Write-Host "Function Key:     $functionKey" -ForegroundColor White
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Update notebooks/hub/nb_hub_api_router_logic.py with the above URL and key"
Write-Host "  2. Update spoke notebooks with your HUB_WORKSPACE_ID"
Write-Host "  3. Deploy notebooks to Fabric (see scripts/deploy-notebooks.ps1)"
Write-Host ""
