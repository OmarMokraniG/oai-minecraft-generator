import hmac
import json
import logging
import os
import re
import secrets
from pathlib import Path
from uuid import UUID

import requests
from azure.core.exceptions import AzureError
from azure.identity import DefaultAzureCredential
from starlette.applications import Starlette
from starlette.concurrency import run_in_threadpool
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import FileResponse, JSONResponse
from starlette.routing import Mount, Route
from starlette.staticfiles import StaticFiles

from invitation_service import AccessManager, AzureApi, InvitationJobs, https_url, normalize_email

logger = logging.getLogger(__name__)
STATIC = Path(__file__).parent / "portal"


def create_app(administrator, base_url, generator_url, jobs, access):
    administrator = str(UUID(administrator))
    base_url = https_url(base_url)
    generator_url = https_url(generator_url)

    async def index(request):
        return FileResponse(STATIC / "index.html")

    async def session(request):
        token = request.cookies.get("portal-csrf", "")
        if not re.fullmatch(r"[A-Za-z0-9_-]{43}", token):
            token = secrets.token_urlsafe(32)
        response = JSONResponse({"csrf": token, "generatorUrl": generator_url})
        response.set_cookie(
            "portal-csrf", token, httponly=True, secure=True, samesite="strict", max_age=3600
        )
        return response

    async def mutation_body(request: Request, fields):
        cookie = request.cookies.get("portal-csrf", "")
        token = request.headers.get("X-CSRF-Token", "")
        if (
            request.headers.get("origin") != base_url
            or not cookie
            or not hmac.compare_digest(cookie, token)
        ):
            return JSONResponse(
                {"error": "Recarga el portal para renovar la sesion."}, status_code=403
            )
        if request.headers.get("content-type", "").split(";")[0] != "application/json":
            return JSONResponse({"error": "Solicitud no valida."}, status_code=400)
        payload = bytearray()
        async for chunk in request.stream():
            payload.extend(chunk)
            if len(payload) > 2048:
                return JSONResponse({"error": "Solicitud demasiado grande."}, status_code=413)
        try:
            body = json.loads(payload)
            if not isinstance(body, dict) or set(body) != fields:
                raise ValueError("Invalid operation fields")
            body["requestId"] = str(UUID(body["requestId"]))
        except (ValueError, TypeError, AttributeError):
            return JSONResponse(
                {"error": "Introduce los datos y una solicitud validos."}, status_code=400
            )
        return body

    async def invitations(request: Request):
        if request.method == "GET":
            executions = await run_in_threadpool(jobs.executions)
            return JSONResponse({"invitations": [jobs.summary(item) for item in executions[:10]]})
        body = await mutation_body(request, {"email", "requestId"})
        if isinstance(body, JSONResponse):
            return body
        try:
            recipient = normalize_email(body["email"])
        except (ValueError, TypeError):
            return JSONResponse({"error": "Introduce un correo valido."}, status_code=400)
        try:
            execution = await run_in_threadpool(jobs.start, recipient, body["requestId"])
        except RuntimeError as exc:
            return JSONResponse({"error": str(exc)}, status_code=409)
        return JSONResponse(execution, status_code=202)

    async def users(request):
        return JSONResponse(await run_in_threadpool(access.users))

    async def revoke(request):
        body = await mutation_body(request, {"requestId"})
        if isinstance(body, JSONResponse):
            return body
        try:
            principal = str(UUID(request.path_params["user_id"]))
        except ValueError:
            return JSONResponse({"error": "Usuario no valido."}, status_code=400)
        if principal == administrator:
            return JSONResponse(
                {
                    "error": "La cuenta administradora esta protegida; no se puede revocar su acceso."
                },
                status_code=403,
            )
        user = await run_in_threadpool(access.describe_user, principal)
        try:
            execution = await run_in_threadpool(
                jobs.revoke, principal, body["requestId"], user["email"] or user["name"]
            )
        except RuntimeError as exc:
            return JSONResponse({"error": str(exc)}, status_code=409)
        return JSONResponse(execution, status_code=202)

    async def status(request):
        name = request.path_params["execution"]
        if not re.fullmatch(r"[a-zA-Z0-9-]{1,100}", name):
            return JSONResponse({"error": "Operacion no valida."}, status_code=400)
        execution = await run_in_threadpool(
            jobs.api.arm, "GET", f"{jobs.resource_id}/executions/{name}"
        )
        return JSONResponse(jobs.summary(execution))

    app = Starlette(
        routes=[
            Route("/health", lambda request: JSONResponse({"status": "ok"})),
            Route("/", index),
            Route("/api/session", session),
            Route("/api/users", users),
            Route("/api/users/{user_id}/revoke", revoke, methods=["POST"]),
            Route("/api/invitations", invitations, methods=["GET", "POST"]),
            Route("/api/invitations/{execution}", status),
            Mount("/static", app=StaticFiles(directory=STATIC)),
        ]
    )

    async def protect(request, call_next):
        if (
            request.url.path != "/health"
            and request.headers.get("X-Ms-Client-Principal-Id") != administrator
        ):
            return JSONResponse(
                {"error": "Solo el administrador puede utilizar este portal."}, status_code=403
            )
        try:
            response = await call_next(request)
        except (AzureError, requests.RequestException, KeyError, ValueError, TimeoutError) as exc:
            logger.error(
                "Invitation portal Azure operation failed: %s HTTP %s",
                type(exc).__name__,
                getattr(getattr(exc, "response", None), "status_code", None),
            )
            response = JSONResponse(
                {
                    "error": "No se pudo consultar o iniciar la operacion en Azure. Reintenta o revisa los registros."
                },
                status_code=502,
            )
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self'; style-src 'self'; "
            "frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        )
        response.headers["Referrer-Policy"] = "same-origin"
        return response

    app.add_middleware(BaseHTTPMiddleware, dispatch=protect)
    return app


if __name__ == "__main__":
    import uvicorn

    credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    api = AzureApi(credential)
    app = create_app(
        os.environ["ADMIN_USER_ID"],
        os.environ["PORTAL_BASE_URL"],
        os.environ["GENERATOR_URL"],
        InvitationJobs(api, os.environ["INVITATION_JOB_RESOURCE_ID"]),
        AccessManager(
            api,
            os.environ["GENERATOR_RESOURCE_ID"],
            os.environ["ADMIN_USER_ID"],
            os.environ["GENERATOR_URL"],
        ),
    )
    uvicorn.run(app, host="0.0.0.0", port=8000, access_log=False)
