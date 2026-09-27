# tetodoro: the web app and the home sync server in one small image.
FROM python:3.13-alpine

WORKDIR /app
COPY server.py ./
COPY static ./static

RUN mkdir /data && chown nobody:nobody /data
USER nobody

ENV TETODORO_DATA=/data \
    PORT=8080 \
    PYTHONUNBUFFERED=1
VOLUME /data
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s \
    CMD wget -qO- "http://127.0.0.1:${PORT}/healthz" || exit 1

CMD ["python", "server.py"]
