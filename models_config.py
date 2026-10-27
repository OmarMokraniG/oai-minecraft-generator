import os
from dataclasses import dataclass
from urllib.parse import urlparse

from dotenv import load_dotenv

load_dotenv()


@dataclass(frozen=True)
class Settings:
    endpoint: str
    image_deployment: str
    vision_deployment: str
    storage_url: str
    container_name: str = "minecraft"
    download_base_url: str = ""

    @classmethod
    def from_env(cls):
        names = (
            "AZURE_OPENAI_ENDPOINT",
            "AZURE_IMAGE_DEPLOYMENT",
            "AZURE_VISION_DEPLOYMENT",
            "AZURE_STORAGE_ACCOUNT_URL",
        )
        values = {name: os.getenv(name, "").strip() for name in names}
        missing = [name for name, value in values.items() if not value]
        if missing:
            raise ValueError(f"Missing configuration: {', '.join(missing)}")
        for name in ("AZURE_OPENAI_ENDPOINT", "AZURE_STORAGE_ACCOUNT_URL"):
            parsed = urlparse(values[name])
            if parsed.scheme != "https" or not parsed.hostname:
                raise ValueError(f"{name} must be an HTTPS URL")
        download_url = os.getenv("PUBLIC_DOWNLOAD_BASE_URL", "").strip().rstrip("/")
        if download_url and (
            urlparse(download_url).scheme != "https" or not urlparse(download_url).hostname
        ):
            raise ValueError("PUBLIC_DOWNLOAD_BASE_URL must be an HTTPS URL")
        return cls(
            endpoint=values[names[0]].rstrip("/"),
            image_deployment=values[names[1]],
            vision_deployment=values[names[2]],
            storage_url=values[names[3]].rstrip("/"),
            download_base_url=download_url,
        )
