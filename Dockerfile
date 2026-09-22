FROM debian:bookworm-slim
# sing-box-extended (shtorm-7) — stock SagerNet builds lack XHTTP transport.
ARG SING_BOX_VERSION=1.13.14-extended-2.5.0
# Default amd64; compose overrides to arm64 for Apple Silicon. Set SING_BOX_ARCH=amd64 on linux/amd64 hosts.
ARG SING_BOX_ARCH=amd64
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl python3 iproute2 procps \
    && curl -fsSL -o /tmp/sb.tgz \
      "https://github.com/shtorm-7/sing-box-extended/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${SING_BOX_ARCH}.tar.gz" \
    && tar -xzf /tmp/sb.tgz -C /tmp \
    && mv /tmp/sing-box-${SING_BOX_VERSION}-linux-${SING_BOX_ARCH}/sing-box /usr/local/bin/sing-box \
    && rm -rf /tmp/sb.tgz /tmp/sing-box-* /var/lib/apt/lists/*
COPY docker/render_config.py /usr/local/lib/spur-gw/render_config.py
COPY docker/clash.sh /usr/local/lib/spur-gw/clash.sh
COPY docker/health.sh /usr/local/lib/spur-gw/health.sh
COPY docker/watchdog.sh /usr/local/lib/spur-gw/watchdog.sh
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
EXPOSE 1090 8128
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
