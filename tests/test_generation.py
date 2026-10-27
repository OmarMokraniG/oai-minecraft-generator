import base64
import io
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
from PIL import Image

from image_generator import ImageGenerator
from models_config import Settings
from webcam_analyzer import WebcamAnalyzer, normalize_photo


@pytest.fixture
def settings():
    return Settings("https://example.openai.azure.com", "image", "vision", "https://blob.example")


def png():
    data = io.BytesIO()
    Image.new("RGB", (32, 32), "green").save(data, format="PNG")
    return data.getvalue()


def test_image_generation_decodes_base64_and_uploads(settings):
    client, storage = MagicMock(), MagicMock()
    client.images.generate.return_value = SimpleNamespace(
        data=[SimpleNamespace(b64_json=base64.b64encode(png()).decode())]
    )
    result = ImageGenerator(settings, client, storage).generate_minecraft_image(
        "Diamond warrior", add_frame=False
    )
    assert result["image_bytes"] == png()
    assert storage.upload_bytes.call_args.args[0].getvalue() == png()
    params = client.images.generate.call_args.kwargs
    assert params["model"] == "image"
    assert "response_format" not in params
    assert params["output_format"] == "png"


@pytest.mark.parametrize("description", [" ", "x" * 2001])
def test_invalid_description_never_calls_model(settings, description):
    client = MagicMock()
    with pytest.raises(ValueError):
        ImageGenerator(settings, client, MagicMock()).generate_minecraft_image(description)
    client.images.generate.assert_not_called()


@pytest.mark.parametrize("data", [[], [SimpleNamespace(b64_json=None)]])
def test_missing_image_is_not_uploaded(settings, data):
    client, storage = MagicMock(), MagicMock()
    client.images.generate.return_value = SimpleNamespace(data=data)
    with pytest.raises(ValueError, match="no image"):
        ImageGenerator(settings, client, storage).generate_minecraft_image("Explorer")
    storage.upload_bytes.assert_not_called()


def test_photo_normalization_reencodes_and_resizes():
    data = io.BytesIO()
    Image.new("RGBA", (2048, 1024), "blue").save(data, format="PNG")
    with Image.open(io.BytesIO(normalize_photo(data.getvalue()))) as image:
        assert image.format == "JPEG"
        assert image.size == (1024, 512)
        assert not image.getexif()


@pytest.mark.parametrize(
    "data",
    [b"", b"not an image", b"x" * (10 * 1024 * 1024 + 1)],
    ids=["empty", "invalid", "oversized"],
)
def test_invalid_photo_is_rejected(data):
    with pytest.raises(ValueError):
        normalize_photo(data)


def test_vision_uses_image_input_without_storing_response(settings):
    client = MagicMock()
    client.responses.create.return_value = SimpleNamespace(output_text="A green explorer")
    result = WebcamAnalyzer(settings, client).analyze_face(png())
    assert result == "A green explorer"
    params = client.responses.create.call_args.kwargs
    assert params["store"] is False
    content = params["input"][0]["content"][0]
    assert content["type"] == "input_image"
    assert content["image_url"].startswith("data:image/jpeg;base64,")


def test_vision_empty_response_is_an_error(settings):
    client = MagicMock()
    client.responses.create.return_value = SimpleNamespace(output_text=" ")
    with pytest.raises(ValueError, match="no description"):
        WebcamAnalyzer(settings, client).analyze_face(png())
