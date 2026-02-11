# syntax=docker/dockerfile:1

# ==============================================================================
# Stage 1: Builder
# Мы убрали '--platform=$BUILDPLATFORM', чтобы сборка шла в эмуляции (QEMU)
# для целевой архитектуры. Это позволяет легко включить CGO.
# ==============================================================================
FROM golang:1.24-alpine AS builder

# Добавляем curl (вместо wget) и build-base (GCC) для CGO
RUN apk add --no-cache git ca-certificates curl jq build-base

ARG TARGETPLATFORM TARGETOS TARGETARCH TARGETVARIANT
ARG OONI_VERSION=""

WORKDIR /src

RUN set -eux; \
    # 1. Логика определения версии
    if [ -n "$OONI_VERSION" ]; then \
        LATEST_VERSION="$OONI_VERSION"; \
        echo "Using specified version: $LATEST_VERSION"; \
    else \
        LATEST_VERSION="$(curl -fsSL -H "User-Agent: Docker-Build" \
            'https://api.github.com/repos/ooni/probe-cli/releases/latest' \
            | jq -r .tag_name)"; \
        echo "Detected latest version from API: $LATEST_VERSION"; \
    fi; \
    \
    if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ]; then \
        echo "Error: Failed to fetch valid version tag from GitHub." >&2; \
        exit 1; \
    fi; \
    \
    VER_NUM="$(echo "${LATEST_VERSION}" | sed 's/^v//')"; \
    \
    # 2. Клонирование
    git clone --depth 1 --branch "${LATEST_VERSION}" \
        https://github.com/ooni/probe-cli.git .; \
    \
    # 3. Настройка GOARM для 32-битных ARM
    # GOOS и GOARCH Go определит сам, так как мы внутри контейнера нужной архитектуры
    case "${TARGETVARIANT}" in \
        v7) export GOARM=7 ;; \
        v6) export GOARM=6 ;; \
        v5) export GOARM=5 ;; \
    esac; \
    \
    # 4. Сборка с CGO
    # Используем -extldflags '-static' для создания полностью статического бинарника,
    # чтобы он гарантированно работал в Runtime-образе.
    CGO_ENABLED=1 go build \
        -ldflags "-s -w -linkmode external -extldflags '-static' -X github.com/ooni/probe-cli/v3/internal/version.Version=${VER_NUM}" \
        -trimpath \
        -o /ooniprobe \
        ./cmd/ooniprobe; \
    \
    if [ ! -f "/ooniprobe" ]; then \
        echo "Error: Build failed, binary not found" >&2; \
        exit 1; \
    fi; \
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
