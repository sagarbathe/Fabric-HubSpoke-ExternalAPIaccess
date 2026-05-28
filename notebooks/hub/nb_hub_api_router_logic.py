# Hub API Router - calls Azure Function and returns results to spoke
import requests
import json

# ============================================================
# UPDATE THESE VALUES after deploying your Azure Function
# ============================================================
FUNCTION_URL = "https://<YOUR-FUNCTION-APP>.azurewebsites.net/api/CallApi"
FUNCTION_KEY = "<YOUR-FUNCTION-KEY>"

print(f"Hub Router: Request from '{spoke_id}' -> api='{api_name}', params={params}")

# Parse params string into dict
params_dict = json.loads(params) if isinstance(params, str) else params

# Call the Azure Function
headers = {
    "Content-Type": "application/json",
    "x-functions-key": FUNCTION_KEY
}
payload = {"api": api_name, "params": params_dict}

try:
    response = requests.post(FUNCTION_URL, headers=headers, json=payload, timeout=30)
    response.raise_for_status()
    result = response.json()
    print(f"Hub Router: Success - api='{api_name}', ok={result.get('ok')}")
except Exception as e:
    result = {"ok": False, "error": str(e), "api": api_name}
    print(f"Hub Router: ERROR - {e}")

notebookutils.notebook.exit(json.dumps(result))
