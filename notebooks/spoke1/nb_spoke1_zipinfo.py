# Spoke 1: Zip Code Info (WS_Spoke1)
# Calls Hub -> Azure Function -> Zippopotam.us API for zip 75022
# Pattern: Spoke1 -> Hub -> Azure Function (CallApi) -> Zippopotam.us -> back
import json
from pyspark.sql.types import StructType, StructField, StringType

# ============================================================
# UPDATE this value with your WS_hub workspace ID
# ============================================================
HUB_WORKSPACE_ID = "<YOUR-HUB-WORKSPACE-ID>"
HUB_NOTEBOOK_NAME = "nb_hub_api_router"
SPOKE_ID = "WS_Spoke1"
API_NAME = "zipinfo"
PARAMS = json.dumps({"zip": "75022"})

print(f"=== {SPOKE_ID}: Requesting '{API_NAME}' API via Hub ===")

result_json = notebookutils.notebook.run(
    HUB_NOTEBOOK_NAME,
    120,
    {"api_name": API_NAME, "params": PARAMS, "spoke_id": SPOKE_ID},
    HUB_WORKSPACE_ID
)

result = json.loads(result_json)

if result.get("ok"):
    print(f"\n{'='*50}")
    print(f" Zip Code Info Results")
    print(f"{'='*50}")
    print(f" Zip Code:   {result.get('zip')}")
    print(f" City:       {result.get('city')}")
    print(f" State:      {result.get('state')} ({result.get('state_abbr')})")
    print(f" Latitude:   {result.get('latitude')}")
    print(f" Longitude:  {result.get('longitude')}")
    print(f" Country:    {result.get('country')}")
    print(f" Fetched At: {result.get('fetched_at')}")
    print(f"{'='*50}")

    schema = StructType([
        StructField("zip", StringType()), StructField("city", StringType()),
        StructField("state", StringType()), StructField("state_abbr", StringType()),
        StructField("latitude", StringType()), StructField("longitude", StringType()),
        StructField("country", StringType()), StructField("spoke_source", StringType())
    ])
    zipinfo_df = spark.createDataFrame([(
        result.get("zip",""), result.get("city",""), result.get("state",""),
        result.get("state_abbr",""), result.get("latitude",""), result.get("longitude",""),
        result.get("country",""), SPOKE_ID
    )], schema=schema)
    zipinfo_df.show(truncate=False)
else:
    print(f"ERROR: {result.get('error', 'Unknown error')}")
