# syntax=docker/dockerfile:1
FROM alpine:3.21

LABEL maintainer="ays7" \
      org.opencontainers.image.title="torproxy" \
      org.opencontainers.image.description="Tor and Privoxy SOCKS/HTTP proxy container" \
      org.opencontainers.image.source="https://github.com/ays7/torproxy"

# Install runtime packages and initialize configuration directories
RUN apk --no-cache upgrade && \
    apk --no-cache add \
        bash \
        curl \
        netcat-openbsd \
        privoxy \
        shadow \
        tini \
        tor \
        tzdata && \
    for f in /etc/privoxy/*.new; do [ -f "$f" ] && cp "$f" "${f%.new}"; done && \
    mkdir -p /etc/tor/run /var/lib/tor /var/log/tor /var/log/privoxy && \
    chown -Rh tor:tor /var/lib/tor /etc/tor /var/log/tor && \
    chmod 0700 /var/lib/tor && \
    chmod 0750 /etc/tor/run && \
    chown -R privoxy:privoxy /etc/privoxy /var/log/privoxy

# Copy configuration templates
COPY config/torrc /etc/tor/torrc
COPY config/privoxy.conf /etc/privoxy/config

# Copy entrypoint script
COPY torproxy.sh /usr/bin/torproxy.sh

RUN chmod +x /usr/bin/torproxy.sh && \
    chown tor:tor /etc/tor/torrc && \
    chown privoxy:privoxy /etc/privoxy/config

EXPOSE 8118 9050 9051

# Local, privacy-preserving healthcheck verifying Privoxy HTTP & Tor SOCKS listeners
HEALTHCHECK --interval=30s --timeout=5s --start-period=25s --retries=3 \
    CMD curl -sf http://127.0.0.1:8118/ >/dev/null && nc -z 127.0.0.1 9050 || exit 1

VOLUME ["/var/lib/tor"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/bin/torproxy.sh"]