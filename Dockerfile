FROM debian:bookworm-slim
# sing-box-extended (shtorm-7) — stock SagerNet builds lack XHTTP transport.
# TARGETARCH is per-platform (amd64 or arm64) and matches the release asset suffix.
# Do not pass an arch build-arg: Buildx applies one value to every platform.
ARG TARGETARCH
ARG SING_BOX_VERSION=1.13.14-extended-2.5.0
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl python3 iproute2 procps \
    && curl -fsSL -o /tmp/sb.tgz \
      "https://github.com/shtorm-7/sing-box-extended/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${TARGETARCH}.tar.gz" \
    && tar -xzf /tmp/sb.tgz -C /tmp \
    && mv /tmp/sing-box-${SING_BOX_VERSION}-linux-${TARGETARCH}/sing-box /usr/local/bin/sing-box \
    && rm -rf /tmp/sb.tgz /tmp/sing-box-* /var/lib/apt/lists/*
COPY docker/render_config.py /usr/local/lib/spur-gw/render_config.py
COPY docker/render_lib/ /usr/local/lib/spur-gw/render_lib/
COPY docker/clash.sh /usr/local/lib/spur-gw/clash.sh
COPY docker/health.sh /usr/local/lib/spur-gw/health.sh
COPY docker/watchdog.sh /usr/local/lib/spur-gw/watchdog.sh
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
EXPOSE 1090 8128
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
