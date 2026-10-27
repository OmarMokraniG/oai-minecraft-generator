FROM node:24-slim AS portal-tested

WORKDIR /source
COPY portal/portal.js portal/portal.js
COPY tests/test_portal_client.cjs tests/test_portal_client.cjs
RUN node --test tests/test_portal_client.cjs

FROM python:3.12-slim AS tested

WORKDIR /source
COPY requirements.txt requirements-dev.txt ./
RUN pip install --no-cache-dir -r requirements-dev.txt
COPY . .
COPY --from=portal-tested /source/portal/portal.js portal/portal.js
RUN ruff check . && ruff format --check . && pytest -q

FROM python:3.12-slim

WORKDIR /app
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    STREAMLIT_BROWSER_GATHER_USAGE_STATS=false \
    STREAMLIT_SERVER_HEADLESS=true \
    STREAMLIT_SERVER_MAX_UPLOAD_SIZE=10

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && useradd --create-home --uid 10001 appuser
COPY --from=tested --chown=appuser:appuser /source/ .
USER appuser
EXPOSE 8501
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD python -c "import os, urllib.request; urllib.request.urlopen(os.getenv('APP_HEALTH_URL', 'http://127.0.0.1:8501/_stcore/health'), timeout=4)"
CMD ["streamlit", "run", "app.py", "--server.port=8501", "--server.address=0.0.0.0"]
