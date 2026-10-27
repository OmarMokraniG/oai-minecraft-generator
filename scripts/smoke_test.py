import io
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import requests
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from image_generator import ImageGenerator  # noqa: E402
from models_config import Settings  # noqa: E402
from webcam_analyzer import WebcamAnalyzer  # noqa: E402


def main():
    settings = Settings.from_env()
    generator = ImageGenerator(settings)
    result = generator.generate_minecraft_image(
        "A friendly explorer with diamond armor and a green scarf"
    )
    with Image.open(io.BytesIO(result["image_bytes"])) as image:
        image.verify()
    print("PASS text-to-image generation, framing and managed-identity upload", flush=True)

    response = requests.get(result["blob_url"], timeout=30)
    response.raise_for_status()
    if response.content != result["image_bytes"]:
        raise AssertionError("Downloaded bytes differ from generated image")
    print("PASS signed QR/download URL", flush=True)

    parsed = urlsplit(result["blob_url"])
    unsigned = urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))
    anonymous = requests.get(unsigned, timeout=30)
    if anonymous.status_code not in (401, 403, 404, 409):
        raise AssertionError("Anonymous blob download unexpectedly succeeded")
    print("PASS anonymous blob access denied", flush=True)

    features = WebcamAnalyzer(settings).analyze_face(result["image_bytes"])
    if not features.strip():
        raise AssertionError("Vision returned no character description")
    print("PASS vision analysis using generated test image (no personal photo)", flush=True)
    time.sleep(65)
    photo_result = generator.generate_minecraft_image(features, add_frame=False)
    with Image.open(io.BytesIO(photo_result["image_bytes"])) as image:
        image.verify()
    print("PASS photo-to-character pipeline", flush=True)
    print("SMOKE TEST PASSED", flush=True)


if __name__ == "__main__":
    main()
