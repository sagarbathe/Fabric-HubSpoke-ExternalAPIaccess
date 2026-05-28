# Fabric Hub/Spoke External API Access Pattern

A reference implementation for routing external API calls from multiple Microsoft Fabric notebooks through a centralized hub notebook to an Azure Function. This pattern provides controlled, auditable external API access across Fabric workspaces.

## Architecture

```
┌─────────────────────┐     ┌─────────────────────┐
│  WS_Spoke1          │     │  WS_Spoke2          │
│  nb_spoke1_zipinfo  │     │  nb_spoke2_weather  │
│  api: "zipinfo"     │     │  api: "weather"     │
└────────┬────────────┘     └────────┬────────────┘
         │                           │
         └───────────┐   ┌───────────┘
                     ▼   ▼
          ┌──────────────────────────┐
          │  WS_hub                  │
          │  nb_hub_api_router       │
          │  (generic API router)    │
          └────────────┬─────────────┘
                       │
                       ▼
          ┌──────────────────────────┐
          │  Azure Function          │
          │  POST /api/CallApi       │
          │  Routes by "api" field   │
          └──────┬──────────┬────────┘
                 │          │
                 ▼          ▼
         Zippopotam.us   Open-Meteo
         (city/state)    (weather)
```

## How It Works

1. **Spoke notebooks** call the hub notebook cross-workspace via `notebookutils.notebook.run()`
2. **Hub notebook** receives `api_name` + `params`, calls the Azure Function's `/api/CallApi` endpoint
3. **Azure Function** routes the request to the appropriate API handler based on the `api` field
4. Results flow back: Azure Function → Hub → Spoke

### Supported APIs

| API Name | Description | Parameters | External Service |
|----------|-------------|------------|-----------------|
| `weather` | Current weather by zip code | `{"zip": "75022"}` | [Open-Meteo](https://open-meteo.com/) (free) |
| `zipinfo` | City/state lookup by zip | `{"zip": "75022"}` | [Zippopotam.us](https://zippopotam.us/) (free) |

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | Deploy Azure resources | `winget install Microsoft.AzureCLI` |
| [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local) | Local testing | `npm i -g azure-functions-core-tools@4` |
| Python 3.10+ | Function runtime | https://python.org/downloads/ |
| [GitHub CLI](https://cli.github.com/) | (Optional) repo management | `winget install GitHub.cli` |

You also need:
- An Azure subscription with permissions to create resources
- A Microsoft Fabric capacity with at least **3 workspaces** (Hub + 2 Spokes)
- Fabric workspace admin permissions

## Deployment Guide

### Step 1: Create Fabric Workspaces

Create three workspaces in your Fabric tenant:

| Workspace | Role | Description |
|-----------|------|-------------|
| `WS_hub` | Hub | Central routing notebook |
| `WS_Spoke1` | Spoke | Zip code info consumer |
| `WS_Spoke2` | Spoke | Weather data consumer |

Note the **Workspace IDs** (GUIDs) from the Fabric portal URL or via:
```powershell
# List workspaces
$token = az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $token" }
(Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces" -Headers $headers).value |
    Where-Object { $_.displayName -match "WS_" } | Select-Object displayName, id
```

### Step 2: Deploy the Azure Function

```powershell
# Login to Azure
az login

# Run the deployment script
.\scripts\deploy-function-app.ps1 -ResourceGroupName "fabric-hubspoke-rg" -Location "westus3"
```

The script will output:
- **Function URL** (e.g., `https://fn-hubspoke-1234.azurewebsites.net/api/CallApi`)
- **Function Key** (for `x-functions-key` authentication)

Save these values for the next step.

#### Verify the function:
```bash
# Health check (anonymous)
curl https://<your-app>.azurewebsites.net/api/health

# Test weather API
curl -X POST https://<your-app>.azurewebsites.net/api/CallApi \
  -H "Content-Type: application/json" \
  -H "x-functions-key: <your-key>" \
  -d '{"api":"weather","params":{"zip":"75022"}}'

# Test zipinfo API
curl -X POST https://<your-app>.azurewebsites.net/api/CallApi \
  -H "Content-Type: application/json" \
  -H "x-functions-key: <your-key>" \
  -d '{"api":"zipinfo","params":{"zip":"75022"}}'
```

### Step 3: Deploy Notebooks to Fabric

```powershell
.\scripts\deploy-notebooks.ps1 `
    -HubWorkspaceId "<WS_hub GUID>" `
    -Spoke1WorkspaceId "<WS_Spoke1 GUID>" `
    -Spoke2WorkspaceId "<WS_Spoke2 GUID>" `
    -FunctionUrl "https://<your-app>.azurewebsites.net/api/CallApi" `
    -FunctionKey "<your-function-key>"
```

### Step 4: Run the Spoke Notebooks

1. Open **WS_Spoke1** → `nb_spoke1_zipinfo` → Run all cells
   - Returns city/state for zip 75022 (Flower Mound, TX)
2. Open **WS_Spoke2** → `nb_spoke2_weather` → Run all cells
   - Returns current weather for zip 75022

## Project Structure

```
├── README.md
├── function-app/
│   ├── function_app.py              # Azure Function with CallApi router
│   ├── host.json                    # Function host configuration
│   ├── requirements.txt             # Python dependencies
│   ├── .funcignore                  # Files excluded from deployment
│   └── local.settings.json.template # Local dev settings template
├── notebooks/
│   ├── hub/
│   │   ├── nb_hub_api_router_params.py  # Parameters cell (overridden by callers)
│   │   └── nb_hub_api_router_logic.py   # Router logic cell
│   ├── spoke1/
│   │   └── nb_spoke1_zipinfo.py         # Zip code info consumer
│   └── spoke2/
│       └── nb_spoke2_weather.py         # Weather data consumer
└── scripts/
    ├── deploy-function-app.ps1      # Azure Function deployment
    └── deploy-notebooks.ps1         # Fabric notebook deployment
```

## Adding New APIs

To add a new external API:

1. **Add a handler** in `function-app/function_app.py`:
   ```python
   def _handle_myapi(params: dict) -> dict:
       # Call external API and return results
       return {"ok": True, "api": "myapi", "data": ...}
   ```

2. **Register it** in the `API_HANDLERS` dictionary:
   ```python
   API_HANDLERS = {
       "weather": _handle_weather,
       "zipinfo": _handle_zipinfo,
       "myapi": _handle_myapi,  # <-- add here
   }
   ```

3. **Create a spoke notebook** that calls the hub with `api_name = "myapi"`.

No changes needed to the hub notebook — it's fully generic.

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Hub/Spoke via `notebookutils.notebook.run()`** | Cross-workspace execution with parameter passing and return values |
| **Parameters cell in hub** | Fabric injects arguments as variable overrides into cells tagged `parameters` |
| **Azure Function for API calls** | Centralizes secrets, handles retries, decouples notebooks from external APIs |
| **Identity-based storage** | Works in tenants with Azure Policy enforcing `allowSharedKeyAccess=false` |
| **Generic `/api/CallApi` endpoint** | Single endpoint routes to any handler — adding APIs requires no infra changes |
| **Explicit PySpark schemas** | Avoids `CANNOT_DETERMINE_TYPE` errors when DataFrame values might be null |

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `run() got unexpected keyword argument 'workspace_id'` | Wrong parameter name | Use positional args: `run(name, timeout, args, workspace)` |
| `400 Client Error` from function | Empty or missing `api_name` in hub | Ensure hub has a parameters cell tagged `parameters` |
| `CANNOT_DETERMINE_TYPE` | PySpark can't infer schema with None values | Use explicit `StructType` schema |
| Storage `403 Forbidden` during deployment | Tenant policy disabling shared key access | Use `deploy-function-app.ps1` which configures identity-based storage |

## Local Development

```bash
cd function-app
cp local.settings.json.template local.settings.json
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
func start
```

Test locally:
```bash
curl -X POST http://localhost:7071/api/CallApi \
  -H "Content-Type: application/json" \
  -d '{"api":"weather","params":{"zip":"75022"}}'
```

## License

MIT