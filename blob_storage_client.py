from datetime import datetime, timedelta, timezone

from azure.core.exceptions import ResourceExistsError
from azure.identity import DefaultAzureCredential
from azure.storage.blob import (
    BlobSasPermissions,
    BlobServiceClient,
    ContentSettings,
    generate_blob_sas,
)


class BlobStorageClient:
    def __init__(self, settings, service_client=None):
        self.container_name = settings.container_name
        self.download_base_url = settings.download_base_url
        self.blob_service_client = (
            service_client
            if service_client is not None
            else BlobServiceClient(
                account_url=settings.storage_url,
                credential=DefaultAzureCredential(exclude_interactive_browser_credential=True),
            )
        )

    def upload_bytes(self, bytes_data, blob_name):
        container = self.blob_service_client.get_container_client(self.container_name)
        try:
            container.create_container()
        except ResourceExistsError:
            pass
        bytes_data.seek(0)
        blob = container.get_blob_client(blob_name)
        blob.upload_blob(
            bytes_data,
            overwrite=False,
            content_settings=ContentSettings(
                content_type="image/png",
                content_disposition=f'inline; filename="{blob_name}"',
            ),
        )

    def get_blob_url(self, blob_name):
        now = datetime.now(timezone.utc)
        start = now - timedelta(minutes=5)
        expiry = now + timedelta(hours=1)
        key = self.blob_service_client.get_user_delegation_key(
            key_start_time=start, key_expiry_time=expiry
        )
        token = generate_blob_sas(
            account_name=self.blob_service_client.account_name,
            container_name=self.container_name,
            blob_name=blob_name,
            user_delegation_key=key,
            permission=BlobSasPermissions(read=True),
            start=start,
            expiry=expiry,
            protocol="https",
        )
        blob = self.blob_service_client.get_blob_client(self.container_name, blob_name)
        if self.download_base_url:
            return f"{self.download_base_url}/images/{blob_name}?{token}"
        return f"{blob.url}?{token}"
