#!/bin/sh
set -eu

APP_USER="${APP_USER:-ooni}"

uid="$(id -u "$APP_USER")"
gid="$(id -g "$APP_USER")"

# Настройки авто-фикса
AUTO_FIX_PERMS="${AUTO_FIX_PERMS:-true}"
AUTO_CHOWN_RECURSIVE="${AUTO_CHOWN_RECURSIVE:-false}"
FAIL_ON_PERMS="${FAIL_ON_PERMS:-true}"

# Обязательные точки монтирования/директории
mkdir -p /config /data

# HOME/XDG — в /data, чтобы ooniprobe не лез в /home/ooni
export HOME="${HOME:-/data}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

# Проверка write как целевого пользователя
can_write_as_user() {
  su-exec "$uid:$gid" sh -ec 'test -w /config && test -w /data'
}

# 1) Если нет прав — пробуем поправить владельца томов
if [ "$AUTO_FIX_PERMS" = "true" ]; then
  if ! can_write_as_user; then
    # best-effort: может провалиться на FS без поддержки chown
    chown "$uid:$gid" /config /data 2>/dev/null || true

    if [ "$AUTO_CHOWN_RECURSIVE" = "true" ]; then
      chown -R "$uid:$gid" /config /data 2>/dev/null || true
    fi
  fi
fi

# 2) Создаём XDG директории уже как целевой пользователь (чтобы не требовался DAC_OVERRIDE)
if su-exec "$uid:$gid" sh -ec "mkdir -p '$XDG_CACHE_HOME' '$XDG_CONFIG_HOME' '$XDG_DATA_HOME'"; then
  :
else
  echo >&2 "ERROR: cannot create XDG dirs under /data as ${APP_USER} (uid=${uid} gid=${gid})."
  echo >&2 "Check that /data is writable and ownership is correct."
  if [ "$FAIL_ON_PERMS" = "true" ]; then
    exit 1
  fi
fi

# 3) Финальная проверка write прав
if ! can_write_as_user; then
  echo >&2 "ERROR: /config or /data is not writable for ${APP_USER} (uid=${uid} gid=${gid})."
  echo >&2 "Fix host permissions (recommended):"
  echo >&2 "  sudo chown -R ${uid}:${gid} ./config ./data"
  exit 1
fi

# Запуск основного процесса под непривилегированным пользователем
exec su-exec "$uid:$gid" "$@"
