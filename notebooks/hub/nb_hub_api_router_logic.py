# Hub API Router — contains all API-specific logic
# The function app is a generic HTTP proxy; this notebook decides:
#   - Which external URL to call
#   - What method/headers/body to send
#   - How to transform the response for the spoke
import requests
import json

# ============================================================
# UPDATE THESE VALUES after deploying your Azure Function
# ============================================================
FUNCTION_URL = "https://<YOUR-FUNCTION-APP>.azurewebsites.net/api/CallApi"
FUNCTION_KEY = "<YOUR-FUNCTION-KEY>"

# ============================================================
# API REGISTRY — add new APIs here (no function app changes needed)
# ============================================================

# Zip-to-coordinates mapping for weather lookups
ZIP_COORDS = {
    "75022": {"lat": 33.0246, "lon": -97.0969, "city": "Flower Mound, TX"},
    "10001": {"lat": 40.7484, "lon": -73.9967, "city": "New York, NY"},
    "90210": {"lat": 34.0901, "lon": -118.4065, "city": "Beverly Hills, CA"},
    "98052": {"lat": 47.6740, "lon": -122.1215, "city": "Redmond, WA"},
    "94105": {"lat": 37.7898, "lon": -122.3942, "city": "San Francisco, CA"},
}


def build_weather_request(params: dict) -> dict:
    """Build the proxy request for Open-Meteo weather API."""
    zip_code = params.get("zip", "75022")
    coords = ZIP_COORDS.get(zip_code)
    if not coords:
        return {"error": f"Unknown zip code: {zip_code}. Supported: {list(ZIP_COORDS.keys())}"}
    url = (
        f"https://api.open-meteo.com/v1/forecast"
        f"?latitude={coords['lat']}&longitude={coords['lon']}"
        f"&current=temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code"
        f"&temperature_unit=fahrenheit&wind_speed_unit=mph"
    )
    return {"url": url, "method": "GET", "timeout": 15}


def transform_weather_response(proxy_result: dict, params: dict) -> dict:
    """Transform raw Open-Meteo response into a clean result for the spoke."""
    zip_code = params.get("zip", "75022")
    coords = ZIP_COORDS.get(zip_code, {})
    resp = proxy_result.get("response_body", {})
    current = resp.get("current", {})
    return {
        "ok": True,
        "api": "weather",
        "zip": zip_code,
        "city": coords.get("city", ""),
        "current": {
            "temperature_f": current.get("temperature_2m"),
            "humidity_pct": current.get("relative_humidity_2m"),
            "wind_speed_mph": current.get("wind_speed_10m"),
            "weather_code": current.get("weather_code"),
        },
        "fetched_at": proxy_result.get("fetched_at", ""),
    }


def build_zipinfo_request(params: dict) -> dict:
    """Build the proxy request for Zippopotam.us API."""
    zip_code = params.get("zip", "75022")
    return {"url": f"https://api.zippopotam.us/us/{zip_code}", "method": "GET", "timeout": 15}


def transform_zipinfo_response(proxy_result: dict, params: dict) -> dict:
    """Transform raw Zippopotam response into a clean result for the spoke."""
    zip_code = params.get("zip", "75022")
    resp = proxy_result.get("response_body", {})
    places = resp.get("places", [])
    place = places[0] if places else {}
    return {
        "ok": True,
        "api": "zipinfo",
        "zip": zip_code,
        "city": place.get("place name", ""),
        "state": place.get("state", ""),
        "state_abbr": place.get("state abbreviation", ""),
        "latitude": place.get("latitude", ""),
        "longitude": place.get("longitude", ""),
        "country": resp.get("country", ""),
        "fetched_at": proxy_result.get("fetched_at", ""),
    }


# Registry: maps api_name -> (request_builder, response_transformer)
API_REGISTRY = {
    "weather": (build_weather_request, transform_weather_response),
    "zipinfo": (build_zipinfo_request, transform_zipinfo_response),
}

# ============================================================
# ROUTER LOGIC — do not modify below unless changing the pattern
# ============================================================

print(f"Hub Router: Request from '{spoke_id}' -> api='{api_name}', params={params}")

# Parse params
params_dict = json.loads(params) if isinstance(params, str) else params

# Lookup API in registry
if api_name not in API_REGISTRY:
    result = {"ok": False, "error": f"Unknown api '{api_name}'. Supported: {list(API_REGISTRY.keys())}"}
    notebookutils.notebook.exit(json.dumps(result))

build_request, transform_response = API_REGISTRY[api_name]

# Build the outbound request spec
request_spec = build_request(params_dict)
if "error" in request_spec:
    result = {"ok": False, "error": request_spec["error"], "api": api_name}
    notebookutils.notebook.exit(json.dumps(result))

print(f"Hub Router: Calling proxy -> {request_spec.get('method', 'GET')} {request_spec['url']}")

# Call the generic proxy (function app)
proxy_headers = {
    "Content-Type": "application/json",
    "x-functions-key": FUNCTION_KEY
}

try:
    response = requests.post(FUNCTION_URL, headers=proxy_headers, json=request_spec, timeout=45)
    response.raise_for_status()
    proxy_result = response.json()
except Exception as e:
    result = {"ok": False, "error": f"Proxy call failed: {str(e)}", "api": api_name}
    print(f"Hub Router: ERROR - {e}")
    notebookutils.notebook.exit(json.dumps(result))

# Check proxy-level success
if not proxy_result.get("ok"):
    result = {"ok": False, "error": proxy_result.get("error", "Proxy returned error"), "api": api_name, "status_code": proxy_result.get("status_code")}
    print(f"Hub Router: Proxy error - {result['error']}")
    notebookutils.notebook.exit(json.dumps(result))

# Transform response using API-specific logic
try:
    result = transform_response(proxy_result, params_dict)
    print(f"Hub Router: Success - api='{api_name}', ok={result.get('ok')}")
except Exception as e:
    result = {"ok": False, "error": f"Response transform failed: {str(e)}", "api": api_name}
    print(f"Hub Router: Transform ERROR - {e}")

notebookutils.notebook.exit(json.dumps(result))
