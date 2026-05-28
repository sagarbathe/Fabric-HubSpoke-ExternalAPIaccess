# Spoke 2: Weather (WS_Spoke2)
# Calls Hub -> Azure Function -> Open-Meteo API for zip 75022
# Pattern: Spoke2 -> Hub -> Azure Function (CallApi) -> Open-Meteo -> back
import json
from pyspark.sql.types import StructType, StructField, StringType, FloatType

# ============================================================
# UPDATE this value with your WS_hub workspace ID
# ============================================================
HUB_WORKSPACE_ID = "<YOUR-HUB-WORKSPACE-ID>"
HUB_NOTEBOOK_NAME = "nb_hub_api_router"
SPOKE_ID = "WS_Spoke2"
API_NAME = "weather"
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
    current = result.get("current", {})
    print(f"\n{'='*50}")
    print(f" Weather for {result.get('city')} (Zip: {result.get('zip')})")
    print(f"{'='*50}")
    print(f" Temperature:  {current.get('temperature_f')} F")
    print(f" Humidity:     {current.get('humidity_pct')}%")
    print(f" Wind Speed:   {current.get('wind_speed_mph')} mph")
    print(f" Weather Code: {current.get('weather_code')}")
    print(f" Fetched At:   {result.get('fetched_at')}")
    print(f"{'='*50}")

    schema = StructType([
        StructField("zip", StringType()), StructField("city", StringType()),
        StructField("temperature_f", FloatType()), StructField("humidity_pct", FloatType()),
        StructField("wind_speed_mph", FloatType()), StructField("spoke_source", StringType()),
        StructField("fetched_at", StringType())
    ])
    weather_df = spark.createDataFrame([(
        result.get("zip",""), result.get("city",""),
        float(current.get("temperature_f",0)), float(current.get("humidity_pct",0)),
        float(current.get("wind_speed_mph",0)), SPOKE_ID, result.get("fetched_at","")
    )], schema=schema)
    weather_df.show()
else:
    print(f"ERROR: {result.get('error', 'Unknown error')}")
