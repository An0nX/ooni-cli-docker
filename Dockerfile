# syntax=docker/dockerfile:1

#===============================================================================
# Stage 1: Builder - загрузка бинарника с автоопределением версии и архитектуры
#===============================================================================
FROM alpine:latest AS builder

RUN apk add --no-cache \
        curl \
        jq \
        ca-certificates

WORKDIR /build

RUN set -eux; \
    case "$(uname -m)" in \
        x86_64)                     ARCH="amd64"  ;; \
        aarch64|arm64)              ARCH="arm64"  ;; \
        armv7l|armv7)               ARCH="armv7"  ;; \
        armv6l|armv6)               ARCH="armv6"  ;; \
        i686|i386|x86)              ARCH="386"    ;; \
        *)  echo ">>> Unsupported architecture: $(uname -m)" >&2; \
            echo ">>> Supported: x86_64, aarch64, armv7l, armv6l, i686" >&2; \
            exit 1 ;; \
    esac; \
    PLATFORM="linux-${ARCH}"; \
    \
    LATEST_VERSION="$(curl -fsSL \
        -H 'Accept: application/vnd.github+json' \
        'https://api.github.com/repos/ooni/probe-cli/releases/latest' \
        | jq -r '.tag_name')"; \
    \
    if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ]; then \
        echo ">>> Failed to fetch latest version from GitHub API" >&2; \
        exit 1; \
    fi; \
    \
    DOWNLOAD_URL="https://github.com/ooni/probe-cli/releases/download/${LATEST_VERSION}/ooniprobe-${PLATFORM}"; \
    echo ">>> Architecture: $(uname -m) -> ${PLATFORM}"; \
    echo ">>> Version: ${LATEST_VERSION}"; \
    echo ">>> URL: ${DOWNLOAD_URL}"; \
    \
    curl -fsSL -o ooniprobe "${DOWNLOAD_URL}"; \
    FILE_SIZE=$(stat -f%z ooniprobe 2>/dev/null || stat -c%s ooniprobe 2>/dev/null); \
    if [ "$FILE_SIZE" -lt 10000000 ]; then \
        echo ">>> Downloaded file too small (${FILE_SIZE} bytes), probably an error" >&2; \
        exit 1; \
    fi; \
    chmod +x ooniprobe; \
    \
    echo "${LATEST_VERSION}" > VERSION; \
    echo "${PLATFORM}" > PLATFORM; \
    echo ">>> Successfully downloaded: ooniprobe ${LATEST_VERSION} (${PLATFORM}, ${FILE_SIZE} bytes)"

#===============================================================================
# Stage 2: Runtime - образ + entrypoint для авто-фикса прав / HOME
#===============================================================================
FROM alpine:latest

LABEL org.opencontainers.image.title="OONI Probe" \
      org.opencontainers.image.description="Network measurement tool for detecting internet censorship" \
      org.opencontainers.image.url="https://ooni.org" \
      org.opencontainers.image.source="https://github.com/ooni/probe-cli" \
      org.opencontainers.image.documentation="https://ooni.org/support/ooni-probe-cli" \
      org.opencontainers.image.vendor="OONI" \
      org.opencontainers.image.licenses="BSD-3-Clause"

ARG UID=1000
ARG GID=1000
ARG USERNAME=ooni

RUN set -eux; \
    apk add --no-cache \
        ca-certificates \
        tini \
        tzdata \
        su-exec; \
    \
    addgroup -g "${GID}" "${USERNAME}"; \
    adduser \
        -u "${UID}" \
        -G "${USERNAME}" \
        -h /data \
        -s /sbin/nologin \
        -D \
        -H \
        "${USERNAME}"; \
    \
    mkdir -p /app /config /data; \
    chown -R "${USERNAME}:${USERNAME}" /app /config /data; \
    chmod 750 /app /config /data

WORKDIR /app

# Бинарник в /usr/bin
COPY --from=builder /build/ooniprobe /usr/bin/ooniprobe
COPY --from=builder /build/VERSION /build/PLATFORM /tmp/

# Runner
COPY --chown=${UID}:${GID} ./scripts/probe.sh /app/probe.sh

# Entrypoint с автофиксами
COPY ./scripts/docker-entrypoint.sh /docker-entrypoint.sh

RUN set -eux; \
    chmod 0755 /usr/bin/ooniprobe; \
    chmod 0755 /app/probe.sh; \
    chmod 0755 /docker-entrypoint.sh; \
    ln -sf /usr/bin/ooniprobe /app/ooniprobe; \
    /usr/bin/ooniprobe -version || echo "Warning: version check failed"; \
    rm -f /tmp/VERSION /tmp/PLATFORM || true

VOLUME ["/config", "/data"]

# TZ специально не задаём (ожидаем /etc/localtime с хоста)
ENV CONFIG_DIR=/config \
    DATA_DIR=/data \
    APP_DIR=/app \
    HOME=/data \
    XDG_CACHE_HOME=/data/.cache \
    XDG_CONFIG_HOME=/data/.config \
    XDG_DATA_HOME=/data/.local/share

HEALTHCHECK --interval=60s --timeout=10s --start-period=10s --retries=3 \
    CMD ooniprobe -version >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/docker-entrypoint.sh"]
CMD ["/bin/sh", "/app/probe.sh"]
