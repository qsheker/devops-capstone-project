FROM python:3.9-slim-bookworm AS wheels
WORKDIR /build
COPY requirements-runtime.txt .
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libpq-dev \
    && pip wheel --wheel-dir /wheels -r requirements-runtime.txt

FROM python:3.9-slim-bookworm
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends libpq5 && apt-get clean
COPY requirements-runtime.txt .
RUN --mount=type=bind,from=wheels,source=/wheels,target=/wheels \
    pip install --no-cache-dir --no-index --find-links=/wheels -r requirements-runtime.txt
COPY service ./service
ENV PYTHONUNBUFFERED=1 PORT=8080
USER 10001
EXPOSE 8080
CMD ["sh", "-c", "exec gunicorn --workers 1 --bind 0.0.0.0:${PORT} --access-logfile - service:app"]
