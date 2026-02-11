# syntax=docker/dockerfile:1

# ==============================================================================
# Stage 1: Builder — нативная кросс-компиляция Go для всех архитектур
# ==============================================================================
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS builder

# Устанавливаем git, сертификаты, curl (для скачивания) и jq (для парсинга JSON)
RUN apk add --no-cache git ca-certificates curl jq

ARG TARGETPLATFORM TARGETOS TARGETARCH TARGETVARIANT
ARG OONI_VERSION=""

WORKDIR /src

RUN set -eux; \
    # 1. Логика определения версии
    if [ -n "$OONI_VERSION" ]; then \
        LATEST_VERSION="$OONI_VERSION"; \
        echo "Using specified version: $LATEST_VERSION"; \
    else \
        # Скачиваем JSON и парсим поле tag_name через jq
        # Добавляем User-Agent, чтобы GitHub не блокировал запрос
        LATEST_VERSION="$(curl -sL -H "User-Agent: Docker-Build" \
            'https://api.github.com/repos/ooni/probe-cli/releases/latest' \
            | jq -r .tag_name)"; \
        echo "Detected latest version from API: $LATEST_VERSION"; \
    fi; \
    \
    # 2. Проверка на ошибки (если версия пустая или null)
    if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ]; then \
        echo "ERROR: Failed to fetch valid version tag from GitHub." >&2; \
        exit 1; \
    fi; \
    \
    # Убираем префикс 'v' для флага компиляции (v3.29.0 -> 3.29.0)
    VER_NUM="$(echo "${LATEST_VERSION}" | sed 's/^v//')"; \
    \
    # 3. Клонирование
    git clone --depth 1 --branch "${LATEST_VERSION}" \
        https://github.com/ooni/probe-cli.git .; \
    \
    # 4. Настройка окружения Go
    export GOOS="${TARGETOS}" GOARCH="${TARGETARCH}"; \
    case "${TARGETVARIANT}" in \
        v7) export GOARM=7 ;; \
        v6) export GOARM=6 ;; \
        v5) export GOARM=5 ;; \
    esac; \
    \
    # 5. Сборка
    CGO_ENABLED=0 go build \
        -ldflags "-s -w -X github.com/ooni/probe-cli/v3/internal/version.Version=${VER_NUM}" \
        -trimpath \
        -o /ooniprobe \
        ./cmd/ooniprobe; \
    \
    chmod +x /ooniprobe

# ==============================================================================
# Stage 2: Runtime
# ==============================================================================
FROM alpine:latest

LABEL org.opencontainers.image.title="OONI Probe" \
      org.opencontainers.image.description="Network measurement tool for detecting internet censorship" \
      org.opencontainers.image.url="https://ooni.org" \
      org.opencontainers.image.source="https://github.com/ooni/probe-cli" \
      org.opencontainers.image.documentation="https://ooni.org/support/ooni-probe-cli" \
      org.opencontainers.image.vendor="OONI" \
      org.opencontainers.image.licenses="BSD-3-Clause"

ARG UID=1000 GID=1000 USERNAME=ooni

RUN set -eux; \
    apk add --no-cache ca-certificates tini tzdata su-exec; \
    addgroup -g "${GID}" "${USERNAME}"; \
    adduser -u "${UID}" -G "${USERNAME}" -h /data -s /sbin/nologin -D -H "${USERNAME}"; \
    mkdir -p /app /config /data; \
    chown -R "${USERNAME}:${USERNAME}" /app /config /data; \
    chmod 750 /app /config /data

WORKDIR /app

COPY --from=builder /ooniprobe /usr/bin/ooniprobe
COPY --chown=${UID}:${GID} ./scripts/probe.sh /app/probe.sh
COPY ./scripts/docker-entrypoint.sh /docker-entrypoint.sh

RUN set -eux; \
    chmod 0755 /usr/bin/ooniprobe /app/probe.sh /docker-entrypoint.sh; \
    ooniprobe -version || echo "Warning: cross-arch check skipped"

VOLUME ["/config", "/data"]

ENV CONFIG_DIR=/config DATA_DIR=/data APP_DIR=/app HOME=/data \
    XDG_CACHE_HOME=/data/.cache XDG_CONFIG_HOME=/data/.config \
    XDG_DATA_HOME=/data/.local/share

HEALTHCHECK --interval=60s --timeout=10s --start-period=10s --retries=3 \
    CMD ooniprobe -version >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/docker-entrypoint.sh"]
CMD ["/bin/sh", "/app/probe.sh"]
