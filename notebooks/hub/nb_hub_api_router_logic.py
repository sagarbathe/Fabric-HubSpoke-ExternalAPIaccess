# Hub API Router - Generic proxy caller + lakehouse writer
# Pipeline passes api_url directly; this notebook calls the proxy and writes to lakehouse
import requests
import json
from pyspark.sql import Row
from pyspark.sql.types import StructType, StructField, StringType

# ============================================================
# UPDATE THESE VALUES after deploying your Azure Function
# ============================================================
FUNCTION_URL = "https://fn-hubspoke-8794.azurewebsites.net/api/CallApi"
FUNCTION_KEY = "<YOUR-FUNCTION-KEY>"  # Generate via: az functionapp keys list --name <app> --resource-group <rg>

print(f"Hub Router: api_url='{api_url}', lakehouse='{lakehouse_name}', table='{table_name}'")

# Step 1: Call the Azure Function proxy with the provided API URL
call_headers = {
    "Content-Type": "application/json",
    "x-functions-key": FUNCTION_KEY
}
payload = {
    "url": api_url,
    "method": "GET",
    "headers": {},
    "body": None
}

try:
    response = requests.post(FUNCTION_URL, headers=call_headers, json=payload, timeout=60)
    response.raise_for_status()
    proxy_result = response.json()
    print(f"Hub Router: Proxy returned ok={proxy_result.get('ok')}, status={proxy_result.get('status_code')}")
except Exception as e:
    proxy_result = {"ok": False, "error": str(e)}
    print(f"Hub Router: ERROR calling proxy - {e}")

# Step 2: Write result to lakehouse table (overwrite)
if proxy_result.get("ok"):
    response_body = proxy_result.get("response_body", {})

    # Flatten response to a list of rows for Delta table
    if isinstance(response_body, list):
        data = response_body
    elif isinstance(response_body, dict):
        data = [response_body]
    else:
        data = [{"value": str(response_body)}]

    # Convert all values to strings for generic schema
    rows = []
    if data:
        all_keys = set()
        for item in data:
            if isinstance(item, dict):
                all_keys.update(item.keys())
            else:
                all_keys = {"value"}
                break

        all_keys = sorted(all_keys)
        schema = StructType([StructField(k, StringType(), True) for k in all_keys])

        for item in data:
            if isinstance(item, dict):
                row_vals = [str(item.get(k, "")) for k in all_keys]
            else:
                row_vals = [str(item)]
            rows.append(Row(*row_vals))

        df = spark.createDataFrame(rows, schema)

        # Write to lakehouse table (overwrite)
        table_path = f"abfss://{lakehouse_name}@onelake.dfs.fabric.microsoft.com/Tables/{table_name}"
        df.write.format("delta").mode("overwrite").option("overwriteSchema", "true").save(table_path)
        print(f"Hub Router: Wrote {df.count()} rows to {lakehouse_name}/{table_name}")

        result_output = {"ok": True, "rows_written": df.count(), "table": table_name, "lakehouse": lakehouse_name}
    else:
        result_output = {"ok": True, "rows_written": 0, "table": table_name, "message": "No data returned"}
else:
    result_output = {"ok": False, "error": proxy_result.get("error", "Unknown error")}

notebookutils.notebook.exit(json.dumps(result_output))
