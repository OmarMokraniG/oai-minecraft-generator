import io
from unittest.mock import MagicMock, patch
from urllib.parse import parse_qs, urlsplit

import pytest
from azure.core.exceptions import HttpResponseError, ResourceExistsError

from blob_storage_client import BlobStorageClient
from models_config import Settings


def make_storage():
    settings = Settings("https://ai.example", "image", "vision", "https://blob.example")
    service = MagicMock()
    service.account_name = "teststorage"
    service.get_blob_client.return_value.url = (
        "https://teststorage.blob.core.windows.net/minecraft/test.png"
    )
    return BlobStorageClient(settings, service), service


def test_upload_existing_private_container_and_content_type():
    storage, service = make_storage()
    container = service.get_container_client.return_value
    container.create_container.side_effect = ResourceExistsError("Already exists")
    storage.upload_bytes(io.BytesIO(b"png"), "test.png")
    args = container.get_blob_client.return_value.upload_blob.call_args
    assert args.kwargs["overwrite"] is False
    assert args.kwargs["content_settings"].content_type == "image/png"
    assert "public_access" not in container.create_container.call_args.kwargs


def test_sas_uses_delegation_key_https_and_read_only():
    storage, service = make_storage()
    with patch("blob_storage_client.generate_blob_sas", return_value="sp=r&spr=https") as sign:
        url = storage.get_blob_url("test.png")
    params = sign.call_args.kwargs
    assert params["user_delegation_key"] == service.get_user_delegation_key.return_value
    assert str(params["permission"]) == "r"
    assert params["protocol"] == "https"
    assert (params["expiry"] - params["start"]).total_seconds() == 3900
    assert parse_qs(urlsplit(url).query)["sp"] == ["r"]


def test_signing_failure_is_not_replaced_with_an_unsigned_url():
    storage, service = make_storage()
    service.get_user_delegation_key.side_effect = HttpResponseError("Denied")
    with pytest.raises(HttpResponseError):
        storage.get_blob_url("test.png")


def test_private_storage_link_is_served_through_download_gateway():
    settings = Settings(
        "https://ai.example",
        "image",
        "vision",
        "https://private.blob.core.windows.net",
        download_base_url="https://download.example",
    )
    service = MagicMock(account_name="private")
    storage = BlobStorageClient(settings, service)
    with patch("blob_storage_client.generate_blob_sas", return_value="sp=r&sig=signed"):
        assert storage.get_blob_url("test.png") == (
            "https://download.example/images/test.png?sp=r&sig=signed"
        )
