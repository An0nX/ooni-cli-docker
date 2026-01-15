# OONI Probe CLI (Docker)

Docker-образ для запуска **OONI Probe CLI** (ooniprobe) в контейнере с удобным runner-скриптом для периодических измерений.

- Бинарник: `/usr/bin/ooniprobe`
- Скрипт запуска: `/app/probe.sh`
- Контейнер запускается **не от root** (пользователь `ooni`, UID/GID по умолчанию 1000/1000)
- Данные и конфиг — в volume’ах `/config` и `/data`

## Поддерживаемые архитектуры

Образ публикуется как multi-arch для:
- `linux/amd64`
- `linux/arm64`
- `linux/arm/v7`
- `linux/arm/v6`
- `linux/386`

## Как это работает

Контейнер запускает `/app/probe.sh`, который:
1. Проверяет обязательный `informed_consent=true`
2. Генерирует конфиг `/config/config.json` на основе переменных окружения
3. Выбирает режим:
   - Если есть `/config/urls.txt` → запускает тест `websites` по этому списку
   - Иначе → запускает `ooniprobe run unattended` (все тесты)
4. Может работать:
   - один раз (по умолчанию `sleep=false`)
   - или постоянно с паузами между прогонами (`sleep=true`)

## Быстрый старт (одиночный запуск)

```bash
docker run --rm \
  -e informed_consent=true \
  -v "$(pwd)/config:/config" \
  -v "$(pwd)/data:/data" \
  -v /etc/localtime:/etc/localtime:ro \
  whn0thacked/ooniprobe:latest
```

> Примечание: если `sleep=false` (по умолчанию), контейнер выполнит один прогон и завершится.

## Постоянный режим (каждые 6 часов)

```bash
docker run -d \
  --name ooniprobe \
  -e informed_consent=true \
  -e sleep=true \
  -e seconds_between_tests=21600 \
  -v "$(pwd)/config:/config" \
  -v "$(pwd)/data:/data" \
  -v /etc/localtime:/etc/localtime:ro \
  --restart unless-stopped \
  whn0thacked/ooniprobe:latest
```

## Режим websites (своий список URL)

Создайте файл `./config/urls.txt`, по одному URL на строку, например:
```txt
https://example.com
https://ooni.org
https://github.com
```

Запуск:
```bash
docker run --rm \
  -e informed_consent=true \
  -e sleep=false \
  -v "$(pwd)/config:/config" \
  -v "$(pwd)/data:/data" \
  whn0thacked/ooniprobe:latest
```

Если `urls.txt` существует — будет использован тест `run websites --input-file=/config/urls.txt`.

## Переменные окружения

| Переменная | Обяз. | По умолчанию | Описание |
|---|---:|---|---|
| `informed_consent` | да | (нет) | Должно быть `true`, иначе контейнер завершится с ошибкой |
| `upload_results` | нет | `false` | Отправлять результаты в OONI |
| `sleep` | нет | `false` | `true` = контейнер работает постоянно; `false` = один прогон |
| `seconds_between_tests` | нет | `21600` | Интервал между прогонами в секундах (6 часов) |
| `websites_max_runtime` | нет | `0` | Лимит времени для websites тестов |
| `websites_enabled_category_codes` | нет | пусто | CSV категорий (будет конвертировано в JSON массив) |
| `args` | нет | `unattended`* | Доп. аргументы для `ooniprobe run` (см. ниже) |

\* Если `urls.txt` отсутствует, runner делает:
- `ooniprobe run --config=/config/config.json ${args:-unattended}`

## Тома (Volumes)

- `/config` — конфигурация (скрипт пишет сюда `config.json`, и может читать `urls.txt`)
- `/data` — состояние/артефакты runner’а (например `last_run`, `probe.pid`)

Рекомендуется монтировать оба тома на host или использовать named volumes.

## Время / Timezone

В образе `TZ` специально не задан, чтобы можно было “тянуть” время с системы через `localtime`.

Рекомендуемый вариант:
```bash
-v /etc/localtime:/etc/localtime:ro
```

(Опционально, если у вас есть файл timezone):
```bash
-v /etc/timezone:/etc/timezone:ro
```

## “Идеальный” docker-compose.yml

Ниже пример для постоянной работы, с безопасными настройками и корректным временем хоста:

```yaml
services:
  ooniprobe:
    image: whn0thacked/ooniprobe:latest
    container_name: ooniprobe
    restart: unless-stopped

    # Runner settings
    environment:
      informed_consent: "true"
      upload_results: "false"
      sleep: "true"
      seconds_between_tests: "21600"
      # args: "unattended"   # можно не задавать, это дефолт для режима без urls.txt

    # Persist config + state
    volumes:
      - ./config:/config
      - ./data:/data

      # Take timezone from host
      - /etc/localtime:/etc/localtime:ro
      # - /etc/timezone:/etc/timezone:ro

    # Security hardening (обычно работает без проблем)
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

    # (опционально) ограничение ресурсов
    # deploy:
    #   resources:
    #     limits:
    #       cpus: "1.0"
    #       memory: 512M
```

Запуск:
```bash
docker compose up -d
docker compose logs -f
```

## Сборка и публикация multi-arch (для maintainer’а)

Нужно использовать buildx builder с driver `docker-container`:

```bash
docker run --privileged --rm tonistiigi/binfmt --install all

docker buildx create --name multiarch --driver docker-container --use
docker buildx inspect --bootstrap

docker buildx build \
  --platform linux/amd64,linux/arm64,linux/arm/v7,linux/arm/v6,linux/386 \
  -t whn0thacked/ooniprobe:latest \
  --push .
```

## Лицензия

OONI Probe CLI: см. upstream проект https://github.com/ooni/probe-cli
