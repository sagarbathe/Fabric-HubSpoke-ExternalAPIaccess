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

# ---------------------------------------------------------------------------
# API Handlers — each handler takes params dict and returns a result dict
# ---------------------------------------------------------------------------

# Zip-to-coordinates mapping for weather
ZIP_COORDS = {
    "75022": {"lat": 33.0246, "lon": -97.0969, "city": "Flower Mound, TX"},
    "10001": {"lat": 40.7484, "lon": -73.9967, "city": "New York, NY"},
    "90210": {"lat": 34.0901, "lon": -118.4065, "city": "Beverly Hills, CA"},
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
        "ok": True,
        "api": "weather",
        "zip": zip_code,
        "city": coords["city"],
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
        "ok": True,
        "api": "zipinfo",
        "zip": zip_code,
        "city": place.get("place name", ""),
        "state": place.get("state", ""),
        "state_abbr": place.get("state abbreviation", ""),
        "latitude": place.get("latitude", ""),
        "longitude": place.get("longitude", ""),
        "country": data.get("country", ""),
    }


# Registry of supported API types
API_HANDLERS = {
    "weather": _handle_weather,
    "zipinfo": _handle_zipinfo,
}


# ---------------------------------------------------------------------------
# Generic API Router endpoint
# ---------------------------------------------------------------------------

@app.function_name(name="CallApi")
@app.route(route="CallApi", methods=["GET", "POST"])
def call_api(req: func.HttpRequest) -> func.HttpResponse:
    """
    Generic API router. Accepts:
      { "api": "weather"|"zipinfo", "params": { ... } }
    Routes to the appropriate handler and returns results.
    """
    logging.info("CallApi invoked (instance=%s)", _INSTANCE_ID)

    body = {}
    try:
        body = req.get_json() or {}
    except ValueError:
        pass

    api_name = body.get("api") or req.params.get("api") or ""
    params = body.get("params", {})

    if not api_name:
        return func.HttpResponse(
            json.dumps({"ok": False, "error": "Missing 'api' field. Supported: " + ", ".join(API_HANDLERS.keys())}),
            status_code=400, mimetype="application/json",
        )

    handler = API_HANDLERS.get(api_name)
    if not handler:
        return func.HttpResponse(
            json.dumps({"ok": False, "error": f"Unknown api '{api_name}'. Supported: " + ", ".join(API_HANDLERS.keys())}),
            status_code=400, mimetype="application/json",
        )

    try:
        result = handler(params)
        result["fetched_at"] = datetime.now(timezone.utc).isoformat()
        result["instance_id"] = _INSTANCE_ID
        result["function_app"] = os.environ.get("WEBSITE_SITE_NAME", "local")
    except Exception as exc:
        logging.error("API handler '%s' error: %s", api_name, exc)
        result = {"ok": False, "error": str(exc), "api": api_name, "fetched_at": datetime.now(timezone.utc).isoformat(), "instance_id": _INSTANCE_ID}

    return func.HttpResponse(
        json.dumps(result),
        status_code=200 if result.get("ok") else 502,
        mimetype="application/json",
    )


# ---------------------------------------------------------------------------
# Legacy GetWeather endpoint (still works, delegates to handler)
# ---------------------------------------------------------------------------

@app.function_name(name="GetWeather")
@app.route(route="GetWeather", methods=["GET", "POST"])
def get_weather(req: func.HttpRequest) -> func.HttpResponse:
    """Legacy endpoint — calls weather handler directly."""
    logging.info("GetWeather invoked (instance=%s)", _INSTANCE_ID)

    body = {}
    try:
        body = req.get_json() or {}
    except ValueError:
        pass

    params = {"zip": body.get("zip") or req.params.get("zip") or "75022"}
    try:
        response = _handle_weather(params)
        response["fetched_at"] = datetime.now(timezone.utc).isoformat()
        response["instance_id"] = _INSTANCE_ID
        response["function_app"] = os.environ.get("WEBSITE_SITE_NAME", "local")
    except Exception as exc:
        response = {"ok": False, "error": str(exc), "fetched_at": datetime.now(timezone.utc).isoformat(), "instance_id": _INSTANCE_ID}

    return func.HttpResponse(
        json.dumps(response),
        status_code=200 if response.get("ok") else 502,
        mimetype="application/json",
    )


@app.function_name(name="Health")
@app.route(route="health", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def health(req: func.HttpRequest) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps({"ok": True, "instance_id": _INSTANCE_ID, "supported_apis": list(API_HANDLERS.keys())}),
        status_code=200,
        mimetype="application/json",
    )
