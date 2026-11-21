#!/usr/bin/env bash
set -euo pipefail

# Уникальное имя тестового проекта и порт, чтобы не мешать основному запуску
TEST_PROJECT="hw3_autotest_$$"
export APP_PORT="${TEST_APP_PORT:-18080}"
export GREETING="Test check run"

BASE_URL="http://127.0.0.1:${APP_PORT}"
BACKUP_DIR="$(mktemp -d 2>/dev/null || echo "/tmp/redis_bkp_$$")"
mkdir -p "$BACKUP_DIR"
BACKUP_ARCHIVE="${BACKUP_DIR}/redis_backup.tar.gz"
VOLUME_NAME="${TEST_PROJECT}_redis_storage"

N_INCREMENTS=5
CURRENT_STAGE="0. Инициализация окружения"

cleanup() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "[ОШИБКА] Проверка прервана на этапе: ${CURRENT_STAGE} (код: ${code})" >&2
    fi
    echo "[Очистка] Удаление тестовых ресурсов проекта ${TEST_PROJECT}..."
    docker compose -p "$TEST_PROJECT" down -v >/dev/null 2>&1 || true
    rm -rf "$BACKUP_DIR" >/dev/null 2>&1 || true
    exit "$code"
}

trap cleanup EXIT

wait_until_ready() {
    local max_wait=30
    local i=1
    while [ "$i" -le "$max_wait" ]; do
        local status_code
        status_code="$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 3 "${BASE_URL}/readyz" || true)"
        if [ "$status_code" = "200" ]; then
            echo "  -> Сервис готов (HTTP 200 на /readyz, попытка ${i}/${max_wait})"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    echo "Тайм-аут ожидания готовности сервиса (${max_wait} сек)" >&2
    return 1
}

get_counter_value() {
    local response
    response="$(curl -fsS --connect-timeout 2 --max-time 3 "${BASE_URL}/")"
    echo "$response" | grep -o '"count": *[0-9]*' | grep -o '[0-9]*'
}

post_increment_value() {
    local response
    response="$(curl -fsS -X POST --connect-timeout 2 --max-time 3 "${BASE_URL}/increment")"
    echo "$response" | grep -o '"count": *[0-9]*' | grep -o '[0-9]*'
}

get_status_code() {
    local method="$1"
    local endpoint="$2"
    curl -s -o /dev/null -w "%{http_code}" -X "$method" --connect-timeout 2 --max-time 3 "${BASE_URL}${endpoint}"
}

echo "=== Старт автоматической проверки (проект: ${TEST_PROJECT}, порт: ${APP_PORT}) ==="

CURRENT_STAGE="1. Создание тестового Compose-проекта с пустым хранилищем и ожидание готовности"
echo "[Этап 1] ${CURRENT_STAGE}"
docker compose -p "$TEST_PROJECT" down -v >/dev/null 2>&1 || true
docker compose -p "$TEST_PROJECT" up -d --build
wait_until_ready

CURRENT_STAGE="2. Проверка начального счётчика 0 и выполнение N=${N_INCREMENTS} инкрементов"
echo "[Этап 2] ${CURRENT_STAGE}"
initial_val="$(get_counter_value)"
if [ "$initial_val" != "0" ]; then
    echo "Ожидался начальный счётчик 0, получено: ${initial_val}" >&2
    exit 1
fi
echo "  -> Начальное значение счётчика: ${initial_val}"

step=1
while [ "$step" -le "$N_INCREMENTS" ]; do
    cur_val="$(post_increment_value)"
    if [ "$cur_val" != "$step" ]; then
        echo "После инкремента #${step} ожидалось ${step}, получено: ${cur_val}" >&2
        exit 1
    fi
    step=$((step + 1))
done

after_inc_val="$(get_counter_value)"
if [ "$after_inc_val" != "$N_INCREMENTS" ]; then
    echo "Итоговое значение GET / должно быть ${N_INCREMENTS}, получено: ${after_inc_val}" >&2
    exit 1
fi
echo "  -> После ${N_INCREMENTS} запросов POST /increment значение счётчика: ${after_inc_val}"

CURRENT_STAGE="3. Пересоздание только контейнера приложения и проверка сохранности счётчика"
echo "[Этап 3] ${CURRENT_STAGE}"
docker compose -p "$TEST_PROJECT" up -d --force-recreate --no-deps app
wait_until_ready

recreated_val="$(get_counter_value)"
if [ "$recreated_val" != "$N_INCREMENTS" ]; then
    echo "После пересоздания app ожидалось ${N_INCREMENTS}, получено: ${recreated_val}" >&2
    exit 1
fi
echo "  -> Контейнер app пересоздан, счётчик сохранился: ${recreated_val}"

CURRENT_STAGE="4. Проверка отключения и повторного запуска Redis по сценарию уровня 8"
echo "[Этап 4] ${CURRENT_STAGE}"
docker compose -p "$TEST_PROJECT" stop redis

code_health="$(get_status_code GET /healthz)"
code_ready="$(get_status_code GET /readyz)"
code_inc="$(get_status_code POST /increment)"

if [ "$code_health" != "200" ] || [ "$code_ready" != "503" ] || [ "$code_inc" != "503" ]; then
    echo "Неверные коды ответа при остановленном Redis: healthz=${code_health} (ожидался 200), readyz=${code_ready} (ожидался 503), increment=${code_inc} (ожидался 503)" >&2
    exit 1
fi
echo "  -> При остановленном Redis: /healthz=${code_health}, /readyz=${code_ready}, /increment=${code_inc}"

docker compose -p "$TEST_PROJECT" start redis
wait_until_ready

val_after_redis="$(get_counter_value)"
if [ "$val_after_redis" != "$N_INCREMENTS" ]; then
    echo "После перезапуска Redis ожидалось ${N_INCREMENTS}, получено: ${val_after_redis}" >&2
    exit 1
fi

expected_plus_one=$((N_INCREMENTS + 1))
val_plus_one="$(post_increment_value)"
if [ "$val_plus_one" != "$expected_plus_one" ]; then
    echo "Следующий POST после старта Redis должен вернуть ${expected_plus_one}, получено: ${val_plus_one}" >&2
    exit 1
fi
echo "  -> После запуска Redis без рестарта app: GET / вернул ${val_after_redis}, следующий POST вернул ${val_plus_one}"

CURRENT_STAGE="5. Создание согласованной резервной копии данных Redis во внешний файл"
echo "[Этап 5] ${CURRENT_STAGE}"
docker compose -p "$TEST_PROJECT" stop app redis
docker run --rm \
    -v "${VOLUME_NAME}:/data:ro" \
    -v "${BACKUP_DIR}:/backup" \
    redis:7.4-alpine \
    tar -czpf /backup/redis_backup.tar.gz -C /data .

if [ ! -s "$BACKUP_ARCHIVE" ]; then
    echo "Файл резервной копии не создан или пуст: ${BACKUP_ARCHIVE}" >&2
    exit 1
fi
echo "  -> Резервная копия успешно сохранена в ${BACKUP_ARCHIVE}"

CURRENT_STAGE="6. Удаление исходного тестового проекта вместе с volumes через down -v"
echo "[Этап 6] ${CURRENT_STAGE}"
docker compose -p "$TEST_PROJECT" down -v
echo "  -> Исходный проект и его том ${VOLUME_NAME} удалены"

CURRENT_STAGE="7. Восстановление данных из резервной копии в новый том и проверка счётчика"
echo "[Этап 7] ${CURRENT_STAGE}"
docker compose -p "$TEST_PROJECT" up --no-start
docker run --rm \
    -v "${VOLUME_NAME}:/data" \
    -v "${BACKUP_DIR}:/backup:ro" \
    redis:7.4-alpine \
    tar -xzpf /backup/redis_backup.tar.gz -C /data

docker compose -p "$TEST_PROJECT" up -d
wait_until_ready

restored_val="$(get_counter_value)"
if [ "$restored_val" != "$expected_plus_one" ]; then
    echo "После восстановления из бэкапа ожидалось ${expected_plus_one}, получено: ${restored_val}" >&2
    exit 1
fi
echo "  -> Данные успешно восстановлены из резервной копии! Счётчик равен: ${restored_val}"

echo "=== ВСЕ ПРОВЕРКИ УСПЕШНО ПРОЙДЕНЫ ==="
