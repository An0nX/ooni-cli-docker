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
- **🔄 Automation:** Built-in runner for periodic test execution.
- **💾 Persistence:** Persists configuration and run history.
- **🧠 Smart Execution:** Supports both full test suites (`unattended`) and specific site lists (`urls.txt`).

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
| `websites_max_runtime` | No | `0` | Time limit for the websites test. |
| `websites_enabled_category_codes` | No | — | CSV list of website category codes. |
| `args` | No | `unattended` | Arguments for `ooniprobe` (if `urls.txt` is not used). |

### Volumes

| Container Path | Purpose |
|---|---|
| **`/config`** | `config.json` is generated here. You can also place an optional `urls.txt` here. |
| **`/data`** | Stores runner state, caches, and the OONI home directory. |

---

## 🧠 Runner Logic

The `/app/probe.sh` script manages the container behavior:

1.  **Config Generation:** Creates `/config/config.json` based on ENV variables.
2.  **Mode Selection:**
    *   If `/config/urls.txt` exists ➔ runs checks for specific sites:
        `ooniprobe run websites --input-file=/config/urls.txt`
    *   Else ➔ runs the full automatic test suite:
        `ooniprobe run unattended`
3.  **Loop:** If `sleep=true`, the process sleeps for the specified time and repeats step 2.

---

## 🔗 Useful Links

- **CLI Source Code:** [github.com/ooni/probe-cli](https://github.com/ooni/probe-cli)
- **OONI Documentation:** [ooni.org/support/ooni-probe-cli](https://ooni.org/support/ooni-probe-cli/)
