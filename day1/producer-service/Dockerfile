FROM python:3.12-slim

WORKDIR /app

# Install only runtime deps first for layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/
COPY scripts/ ./scripts/

ENV PYTHONUNBUFFERED=1 \
    PRODUCER_PORT=8080 \
    PRODUCER_HOSTNAME=producer-service

EXPOSE 8080

# Run as non-root when possible
RUN useradd -m -u 10001 appuser && chown -R appuser:appuser /app
USER appuser

HEALTHCHECK --interval=5s --timeout=3s --retries=5 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health')"

CMD ["python", "-m", "src.producer.app"]
