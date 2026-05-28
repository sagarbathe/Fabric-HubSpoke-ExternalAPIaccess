<#
.SYNOPSIS
    Deploys notebooks to Microsoft Fabric workspaces.

.DESCRIPTION
    Creates notebooks in the Hub and Spoke workspaces using the Fabric REST API.
    Requires az cli logged in with access to Fabric workspaces.

.PARAMETER HubWorkspaceId
    GUID of the Hub workspace (WS_hub)

.PARAMETER Spoke1WorkspaceId
    GUID of Spoke 1 workspace (WS_Spoke1)

.PARAMETER Spoke2WorkspaceId
    GUID of Spoke 2 workspace (WS_Spoke2)

.PARAMETER FunctionUrl
    The Azure Function CallApi endpoint URL

.PARAMETER FunctionKey
    The Azure Function key
#>

param(
    [Parameter(Mandatory=$true)][string]$HubWorkspaceId,
    [Parameter(Mandatory=$true)][string]$Spoke1WorkspaceId,
    [Parameter(Mandatory=$true)][string]$Spoke2WorkspaceId,
    [Parameter(Mandatory=$true)][string]$FunctionUrl,
    [Parameter(Mandatory=$true)][string]$FunctionKey
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Deploying Notebooks to Fabric Workspaces" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

$token = az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv --only-show-errors

# --- Read notebook source files and inject config ---
$hubParamsCode = Get-Content "$repoRoot\notebooks\hub\nb_hub_api_router_params.py" -Raw
$hubLogicCode = (Get-Content "$repoRoot\notebooks\hub\nb_hub_api_router_logic.py" -Raw) `
    -replace '<YOUR-FUNCTION-APP>.azurewebsites.net/api/CallApi', ($FunctionUrl -replace 'https://','') `
    -replace '<YOUR-FUNCTION-KEY>', $FunctionKey

$spoke1Code = (Get-Content "$repoRoot\notebooks\spoke1\nb_spoke1_zipinfo.py" -Raw) `
    -replace '<YOUR-HUB-WORKSPACE-ID>', $HubWorkspaceId

$spoke2Code = (Get-Content "$repoRoot\notebooks\spoke2\nb_spoke2_weather.py" -Raw) `
    -replace '<YOUR-HUB-WORKSPACE-ID>', $HubWorkspaceId

# --- Helper to build Fabric notebook payload ---
function New-NotebookPayload($name, $cells) {
    $cellObjs = @()
    foreach ($c in $cells) {
        $meta = @{}
        if ($c.is_params) { $meta = @{ tags = @("parameters") } }
        $cellObjs += @{
            cell_type = "code"
            source = @($c.code)
            metadata = $meta
            outputs = @()
            execution_count = $null
        }
    }
    $ipynb = @{
        nbformat = 4; nbformat_minor = 5
        metadata = @{
            kernel_info = @{ name = "synapse_pyspark" }
            kernelspec = @{ name = "synapse_pyspark"; display_name = "Synapse PySpark"; language = "Python" }
            language_info = @{ name = "python" }
        }
        cells = $cellObjs
    }
    $ipynbJson = $ipynb | ConvertTo-Json -Depth 10 -Compress
    $base64Content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ipynbJson))
    return @{
        displayName = $name
        type = "Notebook"
        definition = @{
            format = "ipynb"
            parts = @(@{ path = "notebook-content.py"; payload = $base64Content; payloadType = "InlineBase64" })
        }
    } | ConvertTo-Json -Depth 10 -Compress
}

# --- Deploy Hub notebook ---
Write-Host "`n[1/3] Deploying nb_hub_api_router to Hub workspace..." -ForegroundColor Yellow
$hubPayload = New-NotebookPayload "nb_hub_api_router" @(
    @{ code = $hubParamsCode; is_params = $true },
    @{ code = $hubLogicCode; is_params = $false }
)
$tmpFile = [System.IO.Path]::GetTempFileName()
$hubPayload | Out-File $tmpFile -Encoding utf8
$r = curl -s -X POST "https://api.fabric.microsoft.com/v1/workspaces/$HubWorkspaceId/items" `
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" `
    -d "@$tmpFile" -w "%{http_code}" 2>&1
Remove-Item $tmpFile -Force
Write-Host "  Result: HTTP $($r[-3..-1] -join '')"

# --- Deploy Spoke1 notebook ---
Write-Host "[2/3] Deploying nb_spoke1_zipinfo to Spoke1 workspace..." -ForegroundColor Yellow
$s1Payload = New-NotebookPayload "nb_spoke1_zipinfo" @(@{ code = $spoke1Code; is_params = $false })
$tmpFile = [System.IO.Path]::GetTempFileName()
$s1Payload | Out-File $tmpFile -Encoding utf8
$r = curl -s -X POST "https://api.fabric.microsoft.com/v1/workspaces/$Spoke1WorkspaceId/items" `
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" `
    -d "@$tmpFile" -w "%{http_code}" 2>&1
Remove-Item $tmpFile -Force
Write-Host "  Result: HTTP $($r[-3..-1] -join '')"

# --- Deploy Spoke2 notebook ---
Write-Host "[3/3] Deploying nb_spoke2_weather to Spoke2 workspace..." -ForegroundColor Yellow
$s2Payload = New-NotebookPayload "nb_spoke2_weather" @(@{ code = $spoke2Code; is_params = $false })
$tmpFile = [System.IO.Path]::GetTempFileName()
$s2Payload | Out-File $tmpFile -Encoding utf8
$r = curl -s -X POST "https://api.fabric.microsoft.com/v1/workspaces/$Spoke2WorkspaceId/items" `
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" `
    -d "@$tmpFile" -w "%{http_code}" 2>&1
Remove-Item $tmpFile -Force
Write-Host "  Result: HTTP $($r[-3..-1] -join '')"

Write-Host "`n============================================" -ForegroundColor Green
Write-Host " Notebooks deployed successfully!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Run the spoke notebooks in Fabric to test the hub/spoke pattern."
Write-Host ""
