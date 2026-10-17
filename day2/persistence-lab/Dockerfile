FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/
COPY scripts/ ./scripts/

RUN mkdir -p /app/data && chmod 777 /app/data

ENV PYTHONUNBUFFERED=1 \
    PERSIST_PORT=8080 \
    PERSIST_DATA_DIR=/app/data \
    PERSIST_HOSTNAME=persistence-lab

EXPOSE 8080

HEALTHCHECK --interval=5s --timeout=3s --retries=5 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health')"

CMD ["python", "-m", "src.app.main"]
