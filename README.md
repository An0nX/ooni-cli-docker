# 🐳 OONI Probe Docker

[![Docker Image Size](https://img.shields.io/docker/image-size/whn0thacked/ooniprobe?style=flat-square&logo=docker&color=blue)](https://hub.docker.com/r/whn0thacked/ooniprobe)
[![Docker Pulls](https://img.shields.io/docker/pulls/whn0thacked/ooniprobe?style=flat-square&logo=docker)](https://hub.docker.com/r/whn0thacked/ooniprobe)
[![Architecture](https://img.shields.io/badge/arch-multi--arch-important?style=flat-square)](https://hub.docker.com/r/whn0thacked/ooniprobe/tags)
[![OONI Powered](https://img.shields.io/badge/OONI-Powered-orange?style=flat-square)](https://ooni.org/)

A high-quality, secure, and lightweight Docker image for the **OONI Probe CLI**. Designed to automatically run network measurements in the background.

This image is engineered with a focus on security (**non-root**), correct time handling, and minimal resource consumption.

---

## ✨ Features

- **🔐 Security:** Runs as non-root (UID/GID 1000), supports `read_only` filesystem.
- **🏗 Multi-arch:** Supports `amd64`, `arm64`, `arm/v7`, `arm/v6`, `386`. Perfect for Raspberry Pi and VPS.
- **🔄 Automation:** Built-in runner for periodic test execution with resume support.
- **💾 Persistence:** Persists configuration and run history across restarts.
- **🧠 Smart Execution:** Supports both full test suites (`unattended`) and specific site lists (`urls.txt`).

---

## 🏷 Image Tags

All tags are **multi-arch manifests** supporting: `amd64`, `arm64`, `arm/v7`, `arm/v6`, `386`.

| Tag | Description |
|---|---|
| `latest` | Always tracks the newest ooniprobe-cli release. Rebuilt automatically. |
| `vX.Y.Z` (e.g. `v3.24.0`) | Pinned to a specific ooniprobe version. Recommended for reproducibility. |

```yaml
# Always up to date (recommended for most users):
image: whn0thacked/ooniprobe:latest

# Pinned to a specific version:
image: whn0thacked/ooniprobe:v3.24.0
```

> **Tip:** The `latest` tag is ideal for a "set it and forget it" deployment.
> Use `vX.Y.Z` tags when you need a guaranteed reproducible environment.

---

## ⚠️ Important Notice (Informed Consent)

Running OONI Probe can pose risks depending on your country and ISP.
To run this container, you **must** explicitly confirm your consent to these risks via an environment variable.

> **Learn more about potential risks:** [https://ooni.org/about/risks/](https://ooni.org/about/risks/)

Activation variable: `informed_consent: "true"`

---

## 🚀 Quick Start (Docker Compose)

We strongly recommend using **Docker Compose** for easy management and security configuration.

### 1. Prepare Directories
Since the container runs as user `1000`, create the folders beforehand and set ownership to avoid permission errors (especially on Linux):

```bash
mkdir -p config data
sudo chown -R 1000:1000 config data
```

### 2. Configuration File
Create a `docker-compose.yml` file:

```yaml
services:
  ooniprobe:
    image: whn0thacked/ooniprobe:latest
    container_name: ooniprobe
    restart: unless-stopped

    environment:
      # MANDATORY: Consent confirmation
      informed_consent: "true"

      # Operational settings
      upload_results: "true"           # Upload reports to OONI
      sleep: "true"                    # Infinite loop (daemon mode)
      seconds_between_tests: "21600"   # Interval (sec) = 6 hours

    volumes:
      # Data and configs
      - ./config:/config
      - ./data:/data
      # Time sync with host (critical for correct logs)
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro

    # Hardening (Security improvements)
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m

    # Resource limits (optional but recommended)
    deploy:
      resources:
        limits:
          cpus: "0.10"
          memory: 256M

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

### 3. Start
```bash
docker compose up -d
```
View logs: `docker compose logs -f`

---

## ⚙️ Configuration

### Environment Variables

| Variable | Mandatory | Default | Description |
|---|:---:|---|---|
| `informed_consent` | **Yes** | — | Set to `true` to consent to risks. Container will not start without this. |
| `upload_results` | No | `false` | Upload measurement results to OONI servers. |
| `sleep` | No | `false` | `true` = Daemon mode (repeat every N sec). `false` = Single run and exit. |
| `seconds_between_tests` | No | `21600` | Pause between test runs (in seconds). |
| `websites_max_runtime` | No | `0` | Time limit for the websites test (seconds, `0` = unlimited). |
| `websites_enabled_category_codes` | No | — | CSV list of website category codes (e.g., `NEWS,ANON,MMED`). |
| `args` | No | `unattended` | Arguments for `ooniprobe` (if `urls.txt` is not used). |
| `DEBUG` | No | `0` | Set to `1` to enable verbose debug logging in the runner script. |

### Advanced / Entrypoint Variables

These control startup behavior in `docker-entrypoint.sh`:

| Variable | Default | Description |
|---|---|---|
| `AUTO_FIX_PERMS` | `true` | Attempt to fix volume ownership on startup. |
| `AUTO_CHOWN_RECURSIVE` | `false` | If `true`, recursively chown volumes (can be slow on large datasets). |
| `FAIL_ON_PERMS` | `true` | Exit with error if XDG directories cannot be created. |

### Volumes

| Container Path | Purpose |
|---|---|
| **`/config`** | `config.json` is generated here. You can also place an optional `urls.txt` here. |
| **`/data`** | Stores runner state (`last_run`, `probe.pid`), XDG caches, and the OONI home directory. |

---

## 🧠 Runner Logic

The `/app/probe.sh` script manages the container behavior:

1.  **Validation:** Checks informed consent, validates all env variables, verifies the binary exists and is executable.
2.  **Config Generation:** Creates `/config/config.json` based on ENV variables.
3.  **Resume Support:** Reads `/data/last_run` timestamp. If the interval hasn't elapsed since the last successful run (e.g., after a container restart), the runner waits for the remaining time instead of re-running immediately.
4.  **Mode Selection:**
    *   If `/config/urls.txt` exists ➔ runs checks for specific sites:
        `ooniprobe run websites --input-file=/config/urls.txt`
    *   Else ➔ runs the full automatic test suite:
        `ooniprobe run unattended`
5.  **Loop:** If `sleep=true`, sleeps for the configured interval and repeats from step 3. If `sleep=false`, the container exits after a single run.
6.  **Signal Handling:** Gracefully handles `SIGTERM`/`SIGINT` — stops the running probe child process and cleans up the PID file.

---

## 🛠 Building from Source

```bash
# Build for current architecture (latest ooniprobe version)
docker build -t ooniprobe:local .

# Build with a specific ooniprobe version
docker build --build-arg OONI_VERSION=v3.24.0 -t ooniprobe:v3.24.0 .

# Multi-arch build (requires docker buildx)
docker buildx build \
  --platform linux/amd64,linux/arm64,linux/arm/v7,linux/arm/v6,linux/386 \
  -t whn0thacked/ooniprobe:latest \
  --push .
```

### Build Arguments

| ARG | Default | Description |
|---|---|---|
| `OONI_VERSION` | *(empty = latest)* | ooniprobe-cli git tag to build (e.g., `v3.24.0`). When empty, fetches the latest release automatically. |
| `UID` | `1000` | UID of the runtime user. |
| `GID` | `1000` | GID of the runtime user. |
| `USERNAME` | `ooni` | Name of the runtime user. |

---

## 🔍 Troubleshooting

| Symptom | Solution |
|---|---|
| `Permission denied` on `/config` or `/data` | `sudo chown -R 1000:1000 ./config ./data` |
| Container is `unhealthy` | Run `docker exec ooniprobe ooniprobe -version` to verify the binary |
| Container exits immediately | Ensure `informed_consent: "true"` is set. For daemon mode, also set `sleep: "true"` |
| Tests don't start | Check logs: `docker compose logs ooniprobe` |

---

## 🔗 Useful Links

- **CLI Source Code:** [github.com/ooni/probe-cli](https://github.com/ooni/probe-cli)
- **OONI Documentation:** [ooni.org/support/ooni-probe-cli](https://ooni.org/support/ooni-probe-cli/)
- **Risk Information:** [ooni.org/about/risks](https://ooni.org/about/risks/)
