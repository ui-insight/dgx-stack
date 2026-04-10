FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    poppler-utils \
    libreoffice-core \
    libreoffice-writer \
    libreoffice-calc \
    libreoffice-impress \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

EXPOSE 8001

# Use sh -c so OCR_PORT is expanded at container start. Defaults to 8001
# if the env var is not set. docker-compose.yml passes OCR_PORT through
# from .env and maps the same port on the host side.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${OCR_PORT:-8001}"]
