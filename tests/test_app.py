import io
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

from PIL import Image
from streamlit.testing.v1 import AppTest

import image_generator
import webcam_analyzer


def test_authentication_fails_closed(monkeypatch):
    monkeypatch.setenv("REQUIRE_AUTH", "true")
    monkeypatch.setenv("ALLOWED_USER_IDS", "allowed-user")
    at = AppTest.from_file(Path(__file__).resolve().parents[1] / "app.py").run()
    assert not at.exception
    assert at.error
    assert not at.text_area


def test_text_generation_and_result_survive_rerun(monkeypatch):
    monkeypatch.setenv("REQUIRE_AUTH", "false")
    monkeypatch.setenv("AZURE_OPENAI_ENDPOINT", "https://example.openai.azure.com")
    monkeypatch.setenv("AZURE_IMAGE_DEPLOYMENT", "image")
    monkeypatch.setenv("AZURE_VISION_DEPLOYMENT", "vision")
    monkeypatch.setenv("AZURE_STORAGE_ACCOUNT_URL", "https://example.blob.core.windows.net")
    data = io.BytesIO()
    Image.new("RGB", (32, 32), "green").save(data, format="PNG")
    generator = MagicMock()
    generator.settings = SimpleNamespace(image_deployment="image")
    generator.generate_minecraft_image.return_value = {
        "image_bytes": data.getvalue(),
        "blob_url": "https://example.com/image.png?sp=r",
        "filename": "test.png",
    }
    analyzer = SimpleNamespace(settings=SimpleNamespace(vision_deployment="vision"))
    monkeypatch.setattr(image_generator, "ImageGenerator", lambda settings: generator)
    monkeypatch.setattr(webcam_analyzer, "WebcamAnalyzer", lambda settings: analyzer)
    at = AppTest.from_file(Path(__file__).resolve().parents[1] / "app.py").run()
    at.text_area[0].input("A diamond explorer")
    at.button[0].click().run()
    assert not at.exception
    assert "result" in at.session_state
    generator.generate_minecraft_image.assert_called_once_with("A diamond explorer", add_frame=True)
    at.run()
    assert not at.exception
    assert "result" in at.session_state
    generator.generate_minecraft_image.assert_called_once()
