import logging
import os
import re

from azure.core.exceptions import AzureError, HttpResponseError, ResourceNotFoundError
from azure.storage.blob import BlobClient
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

logger = logging.getLogger(__name__)
FILENAME = re.compile(r"minecraft_[0-9a-f]{32}\.png")
MAX_IMAGE_BYTES = 20 * 1024 * 1024


def image(request: Request):
    filename = request.path_params["filename"]
    query = request.query_params
    if not FILENAME.fullmatch(filename) or len(request.url.query) > 4096:
        return JSONResponse({"error": "Invalid image link"}, status_code=400)
    if (
        query.get("sp") != "r"
        or query.get("spr") != "https"
        or query.get("sr") != "b"
        or not query.get("sig")
    ):
        return JSONResponse({"error": "A signed, read-only link is required"}, status_code=403)
    account_url = os.environ["AZURE_STORAGE_ACCOUNT_URL"].rstrip("/")
    # Storage validates the signature and expiry over the private endpoint.
    blob_url = f"{account_url}/minecraft/{filename}?{request.url.query}"
    try:
        with BlobClient.from_blob_url(
            blob_url, retry_total=0, connection_timeout=10, read_timeout=30
        ) as blob:
            if blob.get_blob_properties().size > MAX_IMAGE_BYTES:
                return JSONResponse({"error": "Image too large"}, status_code=413)
            data = blob.download_blob(max_concurrency=1).readall()
    except ResourceNotFoundError:
        return JSONResponse({"error": "Image not found"}, status_code=404)
    except HttpResponseError as exc:
        if exc.status_code in (401, 403):
            return JSONResponse({"error": "Link is invalid or expired"}, status_code=403)
        logger.error("Storage download failed with HTTP status %s", exc.status_code)
        return JSONResponse({"error": "Storage temporarily unavailable"}, status_code=502)
    except AzureError as exc:
        logger.error("Storage download failed: %s", type(exc).__name__)
        return JSONResponse({"error": "Storage temporarily unavailable"}, status_code=502)
    return Response(
        data,
        media_type="image/png",
        headers={
            "Content-Disposition": f'inline; filename="{filename}"',
            "Cache-Control": "private, no-store",
            "X-Content-Type-Options": "nosniff",
        },
    )


def health(request: Request):
    return JSONResponse({"status": "ok"})


app = Starlette(routes=[Route("/health", health), Route("/images/{filename}", image)])

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000, access_log=False)
