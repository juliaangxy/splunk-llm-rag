# Tiny live data generator: stdlib-only Python, no pip install needed.
FROM python:3.12-slim
WORKDIR /app
COPY incident_datagen.py /app/incident_datagen.py
ENV DATAGEN_MODE=live \
    LIVE_INTERVAL_SEC=60
# HEC_URL and HEC_TOKEN must be supplied at run time (docker run -e ...).
ENTRYPOINT ["python", "/app/incident_datagen.py"]
