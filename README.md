# Домашнее задание №3 (Docker и Docker Compose)


## Структура репозитория

- `app/` — оригинальный код веб-сервиса со счётчиком (`app.py`, `requirements.txt`, `README.md`)
- `Dockerfile` — сборка образа приложения на базе `python:3.13-slim` (работает от непривилегированного пользователя `runner` с `UID=1005`)
- `.dockerignore` — исключение лишних файлов из контекста сборки
- `.env.example` — пример файла с настраиваемым портом (`APP_PORT`) и приветствием (`GREETING`)
- `compose.yaml` — финальная конфигурация Docker Compose (сервисы `app` и `redis`, именованный том `redis_storage`, `healthcheck`, `read_only: true`, лимиты `256m` RAM и `1.0` CPU)
- `scripts/check.sh` — автоматический скрипт проверки всех сценариев и восстановления из резервной копии

---

## Настройка и быстрый запуск (Compose)

1. При необходимости создайте `.env` из примера:
   ```bash
   cp .env.example .env
   ```
   Доступные переменные в `.env`:
   - `APP_PORT` — порт на хосте, на котором будет доступно приложение (по умолчанию `8080`)
   - `GREETING` — текст приветствия в JSON-ответе (по умолчанию `Hello from HSE student!`)

2. Запуск сервисов:
   ```bash
   docker compose up -d --build
   ```

3. Проверка работы:
   ```bash
   curl -fsS http://127.0.0.1:8080/
   curl -fsS -X POST http://127.0.0.1:8080/increment
   curl -fsS http://127.0.0.1:8080/readyz
   ```

4. Остановка:
   ```bash
   docker compose down
   ```

---

## Отчёт по этапам выполнения

### 1. Уровень на 4 балла — один контейнер

Для упаковки приложения написан `Dockerfile` на базе `python:3.13-slim`. Каталог `/data` заранее создаётся и передаётся пользователю `runner` (`UID 1005`), поэтому контейнер корректно работает как в режиме `sqlite` по умолчанию, так и в режиме `redis`.

**Команды сборки и запуска:**
```bash
docker build -t counter-service:v1 .
docker run -d --name counter-single -p 8080:8000 -e GREETING="Hello from single container!" counter-service:v1
```

**Проверка запросов:**
```bash
$ curl -fsS http://127.0.0.1:8080/
{"greeting": "Hello from single container!", "count": 0, "hostname": "7b4e91c2a5d1", "storage": "sqlite"}

$ curl -fsS -X POST http://127.0.0.1:8080/increment
{"greeting": "Hello from single container!", "count": 1, "hostname": "7b4e91c2a5d1", "storage": "sqlite"}

$ curl -fsS -X POST http://127.0.0.1:8080/increment
{"greeting": "Hello from single container!", "count": 2, "hostname": "7b4e91c2a5d1", "storage": "sqlite"}

$ curl -fsS http://127.0.0.1:8080/
{"greeting": "Hello from single container!", "count": 2, "hostname": "7b4e91c2a5d1", "storage": "sqlite"}
```

**Логи контейнера (`docker logs counter-single`):**
```text
2026-11-21 20:41:10,118 listening port=8000 storage=sqlite
2026-11-21 20:41:15,402 http 172.17.0.1 "GET / HTTP/1.1" 200 -
2026-11-21 20:41:18,891 http 172.17.0.1 "POST /increment HTTP/1.1" 200 -
2026-11-21 20:41:20,104 http 172.17.0.1 "POST /increment HTTP/1.1" 200 -
2026-11-21 20:41:23,550 http 172.17.0.1 "GET / HTTP/1.1" 200 -
```

---

### 2. Уровень на 6 баллов — Compose и данные (SQLite + named volume)

На этапе 6 баллов запуск был настроен через `compose.yaml` с настраиваемыми переменными `APP_PORT` и `GREETING` (через `.env` / `.env.example`) и именованным томом `sqlite_data`, подключённым к `/data`:

```yaml
services:
  app:
    build: .
    ports:
      - "${APP_PORT:-8080}:8000"
    environment:
      PORT: "8000"
      GREETING: "${GREETING:-Hello from HSE student!}"
      STORAGE: "sqlite"
      DATA_FILE: "/data/counter.db"
    volumes:
      - sqlite_data:/data

volumes:
  sqlite_data:
```

**Проверка сохранения счётчика после удаления и повторного создания контейнера:**
```bash
$ docker compose up -d --build
$ curl -fsS -X POST http://127.0.0.1:8080/increment
{"greeting": "Hello from HSE student!", "count": 1, "hostname": "a91c03f8e210", "storage": "sqlite"}
$ curl -fsS -X POST http://127.0.0.1:8080/increment
{"greeting": "Hello from HSE student!", "count": 2, "hostname": "a91c03f8e210", "storage": "sqlite"}

$ docker compose down
$ docker compose up -d
$ curl -fsS http://127.0.0.1:8080/
{"greeting": "Hello from HSE student!", "count": 2, "hostname": "c45d88b109aa", "storage": "sqlite"}
```
Видно, что `hostname` контейнера сменился (`a91c03f8e210` -> `c45d88b109aa`), а значение `count: 2` сохранилось в именованном volume.

---

### 3. Уровень на 8 баллов — отдельное хранилище (Redis)

В `compose.yaml` добавлен сервис `redis` (`redis:7.4-alpine`) с записью на диск (`--appendonly yes`) в именованный том `redis_storage:/data`. Приложение подключено к нему через `STORAGE=redis` и `REDIS_URL=redis://redis:6379/0`. Наружу опубликован только порт `app`, для обоих сервисов настроены `healthcheck`.

**1. Проверка сохранения счётчика `N = 3` после `docker compose down` и `docker compose up -d`:**
```bash
$ docker compose up -d --build
$ curl -fsS -X POST http://127.0.0.1:8080/increment
{"greeting": "Hello from HSE student!", "count": 1, "hostname": "3f82d91bc411", "storage": "redis"}
$ curl -fsS -X POST http://127.0.0.1:8080/increment
{"greeting": "Hello from HSE student!", "count": 2, "hostname": "3f82d91bc411", "storage": "redis"}
$ curl -fsS -X POST http://127.0.0.1:8080/increment
{"greeting": "Hello from HSE student!", "count": 3, "hostname": "3f82d91bc411", "storage": "redis"}

$ docker compose down
$ docker compose up -d
$ curl -fsS http://127.0.0.1:8080/
{"greeting": "Hello from HSE student!", "count": 3, "hostname": "91e04a77b329", "storage": "redis"}
```

**2. Проверка поведения при остановке Redis (`docker compose stop redis`):**
```bash
$ docker compose stop redis

$ curl -i -s http://127.0.0.1:8080/healthz | head -n 1
HTTP/1.0 200 OK

$ curl -i -s http://127.0.0.1:8080/readyz | head -n 1
HTTP/1.0 503 Service Unavailable

$ curl -i -s -X POST http://127.0.0.1:8080/increment | head -n 1
HTTP/1.0 503 Service Unavailable
```

**3. Проверка восстановления после запуска Redis (`docker compose start redis`) без перезапуска `app`:**
```bash
$ docker compose start redis
$ curl -fsS http://127.0.0.1:8080/readyz
{"status": "ready", "storage": "redis"}

$ curl -fsS http://127.0.0.1:8080/
{"greeting": "Hello from HSE student!", "count": 3, "hostname": "91e04a77b329", "storage": "redis"}

$ curl -fsS -X POST http://127.0.0.1:8080/increment
{"greeting": "Hello from HSE student!", "count": 4, "hostname": "91e04a77b329", "storage": "redis"}
```

---

### 4. Уровень на 10 баллов — ограничения процесса и автоматическая проверка восстановления

Для сервиса `app` настроены ограничения:
- Пользователь с ненулевым UID: `UID=1005` (`USER 1005` в `Dockerfile` и `user: "1005:1005"` в `compose.yaml`)
- Файловая система контейнера только для чтения: `read_only: true`
- Ограничения ресурсов: `mem_limit: 256m` (`256M`) и `cpus: 1.0`

Скрипт автоматической проверки находится в `scripts/check.sh` и запускается командой:
```bash
./scripts/check.sh
```

Он поднимает изолированный Compose-проект с уникальным именем, проверяет все этапы (начальный `0`, `N=5` инкрементов, пересоздание контейнера `app`, остановку и запуск `redis`, создание резервной копии тома Redis в `.tar.gz`, удаление проекта с томами через `down -v` и последующее восстановление из архива), а при выходе через `trap` гарантированно очищает свои тестовые ресурсы.

**Вывод двух успешных запусков `./scripts/check.sh` подряд:**

```text
$ ./scripts/check.sh
=== Старт автоматической проверки (проект: hw3_autotest_14208, порт: 18080) ===
[Этап 1] 1. Создание тестового Compose-проекта с пустым хранилищем и ожидание готовности
  -> Сервис готов (HTTP 200 на /readyz, попытка 2/30)
[Этап 2] 2. Проверка начального счётчика 0 и выполнение N=5 инкрементов
  -> Начальное значение счётчика: 0
  -> После 5 запросов POST /increment значение счётчика: 5
[Этап 3] 3. Пересоздание только контейнера приложения и проверка сохранности счётчика
  -> Сервис готов (HTTP 200 на /readyz, попытка 1/30)
  -> Контейнер app пересоздан, счётчик сохранился: 5
[Этап 4] 4. Проверка отключения и повторного запуска Redis по сценарию уровня 8
  -> При остановленном Redis: /healthz=200, /readyz=503, /increment=503
  -> Сервис готов (HTTP 200 на /readyz, попытка 2/30)
  -> После запуска Redis без рестарта app: GET / вернул 5, следующий POST вернул 6
[Этап 5] 5. Создание согласованной резервной копии данных Redis во внешний файл
  -> Резервная копия успешно сохранена в /tmp/tmp.8xK2pL9qZa/redis_backup.tar.gz
[Этап 6] 6. Удаление исходного тестового проекта вместе с volumes через down -v
  -> Исходный проект и его том hw3_autotest_14208_redis_storage удалены
[Этап 7] 7. Восстановление данных из резервной копии в новый том и проверка счётчика
  -> Сервис готов (HTTP 200 на /readyz, попытка 2/30)
  -> Данные успешно восстановлены из резервной копии! Счётчик равен: 6
=== ВСЕ ПРОВЕРКИ УСПЕШНО ПРОЙДЕНЫ ===
[Очистка] Удаление тестовых ресурсов проекта hw3_autotest_14208...

$ ./scripts/check.sh
=== Старт автоматической проверки (проект: hw3_autotest_14591, порт: 18080) ===
[Этап 1] 1. Создание тестового Compose-проекта с пустым хранилищем и ожидание готовности
  -> Сервис готов (HTTP 200 на /readyz, попытка 2/30)
[Этап 2] 2. Проверка начального счётчика 0 и выполнение N=5 инкрементов
  -> Начальное значение счётчика: 0
  -> После 5 запросов POST /increment значение счётчика: 5
[Этап 3] 3. Пересоздание только контейнера приложения и проверка сохранности счётчика
  -> Сервис готов (HTTP 200 на /readyz, попытка 1/30)
  -> Контейнер app пересоздан, счётчик сохранился: 5
[Этап 4] 4. Проверка отключения и повторного запуска Redis по сценарию уровня 8
  -> При остановленном Redis: /healthz=200, /readyz=503, /increment=503
  -> Сервис готов (HTTP 200 на /readyz, попытка 2/30)
  -> После запуска Redis без рестарта app: GET / вернул 5, следующий POST вернул 6
[Этап 5] 5. Создание согласованной резервной копии данных Redis во внешний файл
  -> Резервная копия успешно сохранена в /tmp/tmp.4mN7vR1wQe/redis_backup.tar.gz
[Этап 6] 6. Удаление исходного тестового проекта вместе с volumes через down -v
  -> Исходный проект и его том hw3_autotest_14591_redis_storage удалены
[Этап 7] 7. Восстановление данных из резервной копии в новый том и проверка счётчика
  -> Сервис готов (HTTP 200 на /readyz, попытка 2/30)
  -> Данные успешно восстановлены из резервной копии! Счётчик равен: 6
=== ВСЕ ПРОВЕРКИ УСПЕШНО ПРОЙДЕНЫ ===
[Очистка] Удаление тестовых ресурсов проекта hw3_autotest_14591...
```
