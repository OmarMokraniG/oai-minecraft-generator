import io
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
import streamlit as st
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


@pytest.fixture
def configured_app(monkeypatch):
    st.cache_resource.clear()
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
    analyzer = MagicMock()
    analyzer.settings = SimpleNamespace(vision_deployment="vision")
    analyzer.analyze_face.return_value = "Un explorador con capa verde."
    photo = {"value": None}
    monkeypatch.setattr(st, "file_uploader", lambda *args, **kwargs: photo["value"])
    monkeypatch.setattr(st, "camera_input", lambda *args, **kwargs: photo["value"])
    monkeypatch.setattr(image_generator, "ImageGenerator", lambda settings: generator)
    monkeypatch.setattr(webcam_analyzer, "WebcamAnalyzer", lambda settings: analyzer)
    at = AppTest.from_file(Path(__file__).resolve().parents[1] / "app.py").run()
    return at, generator, analyzer, photo


def test_text_generation_and_result_survive_rerun(configured_app):
    at, generator, _, _ = configured_app
    at.text_area[0].input("A diamond explorer")
    at.button[0].click().run()
    assert not at.exception
    assert "result" in at.session_state
    generator.generate_minecraft_image.assert_called_once_with("A diamond explorer", add_frame=True)
    at.run()
    assert not at.exception
    assert "result" in at.session_state
    generator.generate_minecraft_image.assert_called_once()


@pytest.mark.parametrize("administrator", ["local", "another-user"])
def test_invitation_link_is_only_shown_to_administrator(configured_app, monkeypatch, administrator):
    at, _, _, _ = configured_app
    monkeypatch.setenv("ADMIN_USER_ID", administrator)
    monkeypatch.setenv("ADMIN_PORTAL_URL", "https://portal.example.com")
    at.run()
    assert not at.exception
    assert len(at.get("link_button")) == (1 if administrator == "local" else 0)


@pytest.mark.parametrize("camera", [False, True])
def test_photo_preview_requires_consent_and_is_reused_for_generation(configured_app, camera):
    at, generator, analyzer, photo = configured_app
    at.checkbox[1].set_value(camera).run()
    photo["value"] = io.BytesIO(b"first photo")
    at.run()
    analyzer.analyze_face.assert_not_called()
    at.checkbox[2].check().run()
    assert not at.exception
    analyzer.analyze_face.assert_called_once_with(b"first photo")
    assert any(info.value == "Un explorador con capa verde." for info in at.info)
    generator.generate_minecraft_image.assert_not_called()
    at.run()
    analyzer.analyze_face.assert_called_once()
    at.text_input[0].input("Con una espada azul").run()
    next(button for button in at.button if button.label == "Crear desde la foto").click().run()
    assert not at.exception
    generator.generate_minecraft_image.assert_called_once_with(
        "Un explorador con capa verde. Con una espada azul", add_frame=True
    )
    analyzer.analyze_face.assert_called_once()
    at.checkbox[2].uncheck().run()
    assert not at.info
    assert next(button for button in at.button if button.label == "Crear desde la foto").disabled


def test_changed_photo_does_not_keep_previous_analysis_after_failure(configured_app):
    at, generator, analyzer, photo = configured_app
    photo["value"] = io.BytesIO(b"first photo")
    at.checkbox[2].check().run()
    assert at.info
    at.session_state["last_photo_attempt"] = -60
    analyzer.analyze_face.side_effect = ValueError("Invalid photo")
    photo["value"] = io.BytesIO(b"second photo")
    at.run()
    assert not at.exception
    assert at.error
    assert not at.info
    assert next(button for button in at.button if button.label == "Crear desde la foto").disabled
    generator.generate_minecraft_image.assert_not_called()
    at.run()
    assert analyzer.analyze_face.call_count == 2


def test_photo_generation_rejects_trigger_without_analysis(configured_app, monkeypatch):
    at, generator, analyzer, _ = configured_app
    at.text_input[0].input("Una espada azul").run()
    original_button = st.button

    def stale_submit(label, *args, **kwargs):
        pressed = original_button(label, *args, **kwargs)
        return pressed or label == "Crear desde la foto"

    monkeypatch.setattr(st, "button", stale_submit)
    at.run()
    assert not at.exception
    assert at.warning
    analyzer.analyze_face.assert_not_called()
    generator.generate_minecraft_image.assert_not_called()
