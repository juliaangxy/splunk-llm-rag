# Standalone token-metering reverse proxy. Dependency-free (Python stdlib only), so the
# image is tiny and works in airgapped/offline environments. Drop it in front of any
# OpenAI-compatible or Ollama model server on whatever GPU/CPU compute runs the models.
# Alpine is safe here because there are no third-party/C dependencies to compile.
FROM python:3.12-alpine

WORKDIR /app
COPY app.py /app/app.py

# Non-root for safety.
RUN adduser -D -u 10001 meter
USER meter

ENV LISTEN_PORT=8100 \
    HEC_INDEX=token_metrics \
    HEC_SOURCETYPE=token_metrics \
    BACKEND_LABEL=upstream

EXPOSE 8100
ENTRYPOINT ["python3", "/app/app.py"]
