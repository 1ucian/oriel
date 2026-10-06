FROM python:3.12-slim@sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /opt/oriel
COPY relay/requirements.txt /opt/oriel/relay/requirements.txt
RUN pip install --no-cache-dir -r /opt/oriel/relay/requirements.txt
COPY relay /opt/oriel/relay

RUN useradd --system --uid 10001 --home /nonexistent --shell /usr/sbin/nologin oriel-relay
USER 10001:10001

EXPOSE 443
ENTRYPOINT ["python", "-m", "relay.oriel_relay"]
CMD ["--host", "0.0.0.0", "--port", "443", "--tls-cert", "/run/tls/tls.crt", "--tls-key", "/run/tls/tls.key", "--max-pending", "1024"]
