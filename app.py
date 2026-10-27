import hashlib
import logging
import os
import threading
import time

import streamlit as st
from azure.core.exceptions import AzureError
from openai import OpenAIError

from image_generator import ImageGenerator
from models_config import Settings
from qr_code_generator import generate_qr_code
from webcam_analyzer import WebcamAnalyzer

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

st.set_page_config(page_title="Minecraft Character Studio", page_icon="⛏️", layout="centered")


@st.cache_resource
def services():
    settings = Settings.from_env()
    return ImageGenerator(settings), WebcamAnalyzer(settings), threading.Lock()


def require_user():
    if os.getenv("REQUIRE_AUTH", "true").lower() != "true":
        return "local"
    principal = st.context.headers.get("X-Ms-Client-Principal-Id", "")
    allowed = {
        value.strip() for value in os.getenv("ALLOWED_USER_IDS", "").split(",") if value.strip()
    }
    if not principal or principal not in allowed:
        st.error("Inicia sesion con una cuenta autorizada para utilizar el generador.")
        st.stop()
    return principal


def analyze_photo(analyzer, generation_lock, photo):
    fingerprint = hashlib.sha256(photo).hexdigest() if photo else None
    if fingerprint != st.session_state.get("photo_fingerprint"):
        st.session_state.pop("photo_analysis", None)
        st.session_state.pop("photo_attempted", None)
        st.session_state.photo_fingerprint = fingerprint

    retry = st.button("Volver a analizar", disabled=photo is None)
    if photo is not None and (retry or st.session_state.get("photo_attempted") != fingerprint):
        st.session_state.photo_attempted = fingerprint
        if time.monotonic() - st.session_state.get("last_photo_attempt", -60) < 30:
            st.warning("Espera 30 segundos y pulsa Volver a analizar.")
        elif not generation_lock.acquire(blocking=False):
            st.warning("Hay otra operacion en curso. Pulsa Volver a analizar cuando termine.")
        else:
            st.session_state.last_photo_attempt = time.monotonic()
            st.session_state.pop("photo_analysis", None)
            try:
                with st.spinner("Analizando lo que ve la camara..."):
                    st.session_state.photo_analysis = analyzer.analyze_face(photo)
            except (OpenAIError, AzureError, ValueError, OSError):
                logger.exception("Photo analysis failed")
                st.error("No se pudo analizar la foto. Pulsa Volver a analizar para reintentarlo.")
            finally:
                generation_lock.release()
    analysis = st.session_state.get("photo_analysis")
    if analysis:
        st.subheader("Lo que ve la IA")
        st.info(analysis)
    return analysis


def main():
    principal = require_user()
    st.title("⛏️ Minecraft Character Studio")
    st.write("Convierte una idea o una foto en tu propio personaje de Minecraft.")
    st.caption(
        "Las fotos se envian al modelo para analizarlas; no se guardan en Blob Storage. "
        "Solo se almacena el personaje generado."
    )
    if principal == os.getenv("ADMIN_USER_ID") and os.getenv("ADMIN_PORTAL_URL"):
        st.link_button("Invitar compañeros y amigos", os.environ["ADMIN_PORTAL_URL"])
    try:
        generator, analyzer, generation_lock = services()
    except ValueError:
        logger.exception("Application configuration is invalid")
        st.error("La aplicacion no esta configurada. Contacta con el administrador.")
        st.stop()

    with st.expander("Modelos y privacidad"):
        st.write(f"Imagen: **{generator.settings.image_deployment}**")
        st.write(f"Vision: **{analyzer.settings.vision_deployment}**")
        st.write(
            "Los enlaces de descarga y QR caducan en una hora. Cualquier persona "
            "que tenga el enlace puede descargar esa imagen durante ese tiempo. "
            "Usa solo fotos que tengas permiso para enviar."
        )
        if os.getenv("REQUIRE_AUTH", "true").lower() == "true":
            st.link_button("Cerrar sesion", "/.auth/logout")

    text_tab, photo_tab = st.tabs(["Desde una descripcion", "Desde una foto"])
    description = None
    add_frame = True
    with text_tab:
        with st.form("text_generation"):
            text = st.text_area(
                "Describe tu personaje",
                placeholder="Un explorador con armadura de diamante y una espada brillante",
                max_chars=1000,
            )
            text_frame = st.checkbox("Anadir marco", value=True, key="text_frame")
            text_submit = st.form_submit_button("Generar personaje", type="primary")
        if text_submit:
            description = text.strip()
            add_frame = text_frame
            if not description:
                st.warning("Escribe una descripcion antes de generar.")
                description = None

    with photo_tab:
        use_camera = st.checkbox("Usar la webcam")
        consent = st.checkbox("Tengo permiso para enviar esta foto al servicio de IA")
        if use_camera:
            uploaded = st.camera_input("Haz una foto")
        else:
            uploaded = st.file_uploader(
                "Sube una foto (maximo 10 MB)", type=["jpg", "jpeg", "png", "webp"]
            )
        st.caption(
            "Con tu permiso, cada foto nueva se analiza automaticamente. "
            "Veras la descripcion antes de generar el personaje; no es analisis de video continuo."
        )
        photo = uploaded.getvalue() if uploaded is not None and consent else None
        analysis = analyze_photo(analyzer, generation_lock, photo)
        extra = st.text_input("Detalles adicionales (opcional)", max_chars=500)
        photo_frame = st.checkbox("Anadir marco", value=True, key="photo_frame")
        photo_submit = st.button(
            "Crear desde la foto", type="primary", disabled=analysis is None or not consent
        )
        if photo_submit:
            if analysis is None or not consent:
                st.warning("Confirma el permiso y analiza la foto antes de generar.")
            else:
                description = analysis
                if extra.strip():
                    description = f"{description.rstrip('. ')}. {extra.strip()}"
                add_frame = photo_frame

    if description is not None:
        if time.monotonic() - st.session_state.get("last_attempt", -60) < 30:
            st.warning("Espera 30 segundos entre generaciones.")
        elif not generation_lock.acquire(blocking=False):
            st.warning("Hay otra generacion en curso. Intentalo de nuevo en un momento.")
        else:
            st.session_state.last_attempt = time.monotonic()
            try:
                with st.spinner("Creando tu personaje. Puede tardar uno o dos minutos..."):
                    st.session_state.result = generator.generate_minecraft_image(
                        description, add_frame=add_frame
                    )
                    st.session_state.generated_at = time.time()
            except (OpenAIError, AzureError, ValueError, OSError):
                logger.exception("Character generation failed")
                st.error(
                    "No se pudo crear el personaje. El servicio puede estar ocupado "
                    "o haber rechazado el contenido. Prueba otra vez con otra descripcion."
                )
            finally:
                generation_lock.release()

    if "result" in st.session_state:
        result = st.session_state.result
        st.image(result["image_bytes"], caption="Tu personaje", width="stretch")
        st.download_button(
            "Descargar PNG",
            result["image_bytes"],
            file_name=result["filename"],
            mime="image/png",
            on_click="ignore",
        )
        if time.time() - st.session_state.generated_at < 3500:
            with st.expander("Compartir con QR"):
                st.image(generate_qr_code(result["blob_url"]), width=240)
                st.link_button("Abrir imagen", result["blob_url"])
                st.caption("El enlace permite descargar esta imagen y caduca en una hora.")
        else:
            st.info("El enlace de compartir ha caducado. Puedes descargar el PNG arriba.")


if __name__ == "__main__":
    main()
