from unittest.mock import MagicMock, patch

import pytest
from azure.core.exceptions import HttpResponseError
from starlette.testclient import TestClient

from download_app import app

PATH = "/images/minecraft_" + "a" * 32 + ".png"
SAS = "?sp=r&spr=https&sr=b&sig=test"


@pytest.mark.parametrize("suffix", ["", "?sp=w&spr=https&sr=b&sig=test"])
def test_unsigned_or_write_links_are_denied_before_storage(suffix):
    with patch("download_app.BlobClient.from_blob_url") as blob:
        response = TestClient(app).get(PATH + suffix)
    assert response.status_code == 403
    blob.assert_not_called()


def test_valid_download_uses_fixed_private_storage_url(monkeypatch):
    monkeypatch.setenv("AZURE_STORAGE_ACCOUNT_URL", "https://private.blob.core.windows.net")
    blob = MagicMock()
    blob.get_blob_properties.return_value.size = 3
    blob.download_blob.return_value.readall.return_value = b"png"
    with patch("download_app.BlobClient.from_blob_url") as create:
        create.return_value.__enter__.return_value = blob
        response = TestClient(app).get(PATH + SAS)
    assert response.status_code == 200
    assert response.content == b"png"
    assert response.headers["cache-control"] == "private, no-store"
    assert create.call_args.args[0].startswith(
        "https://private.blob.core.windows.net/minecraft/minecraft_"
    )


def test_expired_sas_is_not_replaced_with_another_credential(monkeypatch):
    monkeypatch.setenv("AZURE_STORAGE_ACCOUNT_URL", "https://private.blob.core.windows.net")
    with patch("download_app.BlobClient.from_blob_url") as create:
        create.return_value.__enter__.side_effect = HttpResponseError(
            "Denied", response=MagicMock(status_code=403, reason="Forbidden")
        )
        response = TestClient(app).get(PATH + SAS)
    assert response.status_code == 403


def test_invalid_filename_cannot_select_another_blob():
    with patch("download_app.BlobClient.from_blob_url") as create:
        response = TestClient(app).get("/images/other-container.png" + SAS)
    assert response.status_code == 400
    create.assert_not_called()
