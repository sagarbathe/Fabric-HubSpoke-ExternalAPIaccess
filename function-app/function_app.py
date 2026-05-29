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
# Generic HTTP Proxy endpoint
# ---------------------------------------------------------------------------

@app.function_name(name="CallApi")
@app.route(route="CallApi", methods=["POST"])
def call_api(req: func.HttpRequest) -> func.HttpResponse:
    """
    Generic HTTP proxy. Accepts a fully-formed request specification and
    executes it, returning the raw response as JSON.

    Request body:
    {
        "url": "https://api.example.com/endpoint",
        "method": "GET" | "POST" | "PUT" | "DELETE",   (default: GET)
        "headers": {"Header-Name": "value", ...},       (optional)
        "body": "..." or {...},                         (optional, for POST/PUT)
        "timeout": 30                                   (optional, default 30s)
    }

    Response:
    {
        "ok": true/false,
        "status_code": 200,
        "response_body": { ... } or "...",
        "response_headers": {"Content-Type": "..."},
        "fetched_at": "2026-...",
        "instance_id": "abc123",
        "function_app": "fn-hubspoke-8794"
    }
    """
    logging.info("CallApi proxy invoked (instance=%s)", _INSTANCE_ID)

    body = {}
    try:
        body = req.get_json() or {}
    except ValueError:
        return func.HttpResponse(
            json.dumps({"ok": False, "error": "Invalid JSON in request body"}),
            status_code=400, mimetype="application/json",
        )

    url = body.get("url", "")
    method = body.get("method", "GET").upper()
    headers = body.get("headers", {})
    request_body = body.get("body")
    timeout = body.get("timeout", 30)

    if not url:
        return func.HttpResponse(
            json.dumps({"ok": False, "error": "Missing 'url' field. Provide the target API URL."}),
            status_code=400, mimetype="application/json",
        )

    # Build the outbound request
    data = None
    if request_body is not None:
        if isinstance(request_body, dict):
            data = json.dumps(request_body).encode("utf-8")
            headers.setdefault("Content-Type", "application/json")
        elif isinstance(request_body, str):
            data = request_body.encode("utf-8")
        else:
            data = json.dumps(request_body).encode("utf-8")

    try:
        http_request = urllib.request.Request(url, data=data, headers=headers, method=method)
        with urllib.request.urlopen(http_request, timeout=timeout) as resp:
            resp_body_raw = resp.read().decode("utf-8")
            resp_headers = dict(resp.headers)
            resp_status = resp.status

        # Try to parse response as JSON
        try:
            response_body = json.loads(resp_body_raw)
        except (json.JSONDecodeError, ValueError):
            response_body = resp_body_raw

        result = {
            "ok": True,
            "status_code": resp_status,
            "response_body": response_body,
            "response_headers": resp_headers,
            "fetched_at": datetime.now(timezone.utc).isoformat(),
            "instance_id": _INSTANCE_ID,
            "function_app": os.environ.get("WEBSITE_SITE_NAME", "local"),
        }
        return func.HttpResponse(json.dumps(result), status_code=200, mimetype="application/json")

    except urllib.error.HTTPError as e:
        error_body = ""
        try:
            error_body = e.read().decode("utf-8")
        except Exception:
            pass
        result = {
            "ok": False,
            "status_code": e.code,
            "error": f"HTTP {e.code}: {e.reason}",
            "response_body": error_body,
            "fetched_at": datetime.now(timezone.utc).isoformat(),
            "instance_id": _INSTANCE_ID,
            "function_app": os.environ.get("WEBSITE_SITE_NAME", "local"),
        }
        return func.HttpResponse(json.dumps(result), status_code=200, mimetype="application/json")

    except Exception as exc:
        logging.error("Proxy error: %s", exc)
        result = {
            "ok": False,
            "error": str(exc),
            "fetched_at": datetime.now(timezone.utc).isoformat(),
            "instance_id": _INSTANCE_ID,
            "function_app": os.environ.get("WEBSITE_SITE_NAME", "local"),
        }
        return func.HttpResponse(json.dumps(result), status_code=502, mimetype="application/json")


@app.function_name(name="Health")
@app.route(route="health", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def health(req: func.HttpRequest) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps({
            "ok": True,
            "instance_id": _INSTANCE_ID,
            "function_app": os.environ.get("WEBSITE_SITE_NAME", "local"),
            "mode": "generic-proxy",
            "description": "Send POST with {url, method, headers, body} to /api/CallApi",
        }),
        status_code=200,
        mimetype="application/json",
    )
