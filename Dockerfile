# syntax=docker/dockerfile:1

#===============================================================================
# Stage 1: Builder - загрузка бинарника с автоопределением версии и архитектуры
#===============================================================================
FROM alpine:latest AS builder

RUN apk add --no-cache \
        curl \
        jq \
        ca-certificates

# Используем TARGETPLATFORM от Docker Buildx вместо uname -m,
# т.к. uname под QEMU может врать
ARG TARGETPLATFORM

WORKDIR /build

RUN set -eux; \
    # --- маппинг TARGETPLATFORM -> суффикс ассета upstream ---
    case "${TARGETPLATFORM}" in \
        linux/amd64)    ASSET_SUFFIX="linux-amd64"  ;; \
        linux/arm64)    ASSET_SUFFIX="linux-arm64"  ;; \
        linux/arm/v7)   ASSET_SUFFIX="linux-armv7"  ;; \
        linux/arm/v6)   ASSET_SUFFIX="linux-armv6"  ;; \
        linux/386)      ASSET_SUFFIX="linux-386"    ;; \
        *)  echo ">>> Unsupported platform: ${TARGETPLATFORM}" >&2; \
            exit 1 ;; \
    esac; \
    \
    # --- определяем последнюю версию ---
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
    # --- ищем нужный ассет через API (а не угадываем URL) ---
    ASSETS_JSON="$(curl -fsSL \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/ooni/probe-cli/releases/tags/${LATEST_VERSION}")"; \
    \
    DOWNLOAD_URL="$(echo "$ASSETS_JSON" | jq -r \
        --arg suffix "$ASSET_SUFFIX" \
        '[.assets[] | select(.name | endswith($suffix))] | first | .browser_download_url // empty' \
    )"; \
    \
    # Если точного совпадения нет — пробуем частичное
    if [ -z "$DOWNLOAD_URL" ]; then \
        DOWNLOAD_URL="$(echo "$ASSETS_JSON" | jq -r \
            --arg suffix "$ASSET_SUFFIX" \
            '[.assets[] | select(.name | contains("ooniprobe") and contains($suffix))] | first | .browser_download_url // empty' \
        )"; \
    fi; \
    \
    if [ -z "$DOWNLOAD_URL" ]; then \
        echo ">>> ERROR: No asset found for '${ASSET_SUFFIX}' in release ${LATEST_VERSION}" >&2; \
        echo ">>> Available assets:" >&2; \
        echo "$ASSETS_JSON" | jq -r '.assets[].name' >&2; \
        exit 1; \
    fi; \
    \
    echo ">>> Platform:  ${TARGETPLATFORM} -> ${ASSET_SUFFIX}"; \
    echo ">>> Version:   ${LATEST_VERSION}"; \
    echo ">>> URL:       ${DOWNLOAD_URL}"; \
    \
    curl -fsSL -o ooniprobe "${DOWNLOAD_URL}"; \
    FILE_SIZE=$(stat -c%s ooniprobe); \
    if [ "$FILE_SIZE" -lt 1000000 ]; then \
        echo ">>> Downloaded file too small (${FILE_SIZE} bytes), probably an error page" >&2; \
        exit 1; \
    fi; \
    chmod +x ooniprobe; \
    \
    echo "${LATEST_VERSION}" > VERSION; \
    echo "${ASSET_SUFFIX}" > PLATFORM; \
    echo ">>> Successfully downloaded: ooniprobe ${LATEST_VERSION} (${ASSET_SUFFIX}, ${FILE_SIZE} bytes)"

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
