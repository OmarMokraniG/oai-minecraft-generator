import base64
import io
import uuid
from pathlib import Path
from typing import TypedDict

from blob_storage_client import BlobStorageClient
from image_frame_processor import ImageFrameProcessor
from openai_utils import create_openai_client

MAX_DESCRIPTION_LENGTH = 2000


class GeneratedImage(TypedDict):
    image_bytes: bytes
    blob_url: str
    filename: str


class ImageGenerator:
    def __init__(self, settings, client=None, blob_client=None):
        self.settings = settings
        self.client = client if client is not None else create_openai_client(settings)
        self.blob_client = blob_client if blob_client is not None else BlobStorageClient(settings)
        self.frame_processor = ImageFrameProcessor()

    def generate_minecraft_image(self, description, add_frame=True) -> GeneratedImage:
        description = description.strip()
        if not description or len(description) > MAX_DESCRIPTION_LENGTH:
            raise ValueError(f"Description must contain 1-{MAX_DESCRIPTION_LENGTH} characters")
        response = self.client.images.generate(
            model=self.settings.image_deployment,
            prompt=(
                "Create a full-body Minecraft-style character based on the description "
                "below. Use a friendly blocky voxel appearance, crisp pixel textures, "
                "a vibrant Minecraft-like landscape, grass blocks and cubic trees. "
                "Keep the whole character visible. No text, logos or watermarks. "
                f"Character description: {description}"
            ),
            n=1,
            size="1024x1024",
            quality="high",
            output_format="png",
        )
        if not response.data or not response.data[0].b64_json:
            raise ValueError("The image model returned no image")
        image_bytes = io.BytesIO(base64.b64decode(response.data[0].b64_json, validate=True))
        frame_path = Path(__file__).parent / "frames" / "frame1.png"
        if add_frame and frame_path.is_file():
            image_bytes = self.frame_processor.add_frame(image_bytes, str(frame_path))
        filename = f"minecraft_{uuid.uuid4().hex}.png"
        self.blob_client.upload_bytes(image_bytes, filename)
        return {
            "image_bytes": image_bytes.getvalue(),
            "blob_url": self.blob_client.get_blob_url(filename),
            "filename": filename,
        }
