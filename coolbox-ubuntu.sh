#!/usr/bin/env bash
# CoolBox AutoFan PRO control utility for Ubuntu.
# Firmware flashing and HiveOS miner commands are intentionally excluded.

set -u

APP_NAME="coolbox"
CONFIG_DIR="/etc/coolbox"
CONFIG_FILE="${CONFIG_DIR}/coolbox.conf"
RUNTIME_DIR="/run/coolbox"
REPLY_FILE="${RUNTIME_DIR}/serial.log"
LOCK_FILE="${RUNTIME_DIR}/request.lock"
LISTENER_PID_FILE="${RUNTIME_DIR}/listener.pid"
SERIAL_PORT="${COOLBOX_SERIAL_PORT:-/dev/ttyUSB0}"
BAUD_RATE=9600
REPLY_TIMEOUT=1.2

AUTO_ENABLED=0
MANUAL_FAN=55
TARGET_TEMP=70
TARGET_MEM_TEMP=70
WATCHDOG=1
WD_RESET_INTERVAL=4

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RESET=$'\033[0m'

log() { printf '%s\n' "$*" >&2; }
die() { log "${RED}Error:${RESET} $*"; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Не найдена команда '$1'. Установите пакет, содержащий её."
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    # Config is shell syntax and should only be writable by root.
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

save_config() {
    install -d -m 0755 "$CONFIG_DIR"
    local tmp
    tmp="$(mktemp "${CONFIG_DIR}/coolbox.conf.XXXXXX")"
    cat >"$tmp" <<EOF
# CoolBox AutoFan PRO settings
AUTO_ENABLED=${AUTO_ENABLED}
MANUAL_FAN=${MANUAL_FAN}
TARGET_TEMP=${TARGET_TEMP}
TARGET_MEM_TEMP=${TARGET_MEM_TEMP}
WATCHDOG=${WATCHDOG}
WD_RESET_INTERVAL=${WD_RESET_INTERVAL}
EOF
    chmod 0644 "$tmp"
    mv "$tmp" "$CONFIG_FILE"
}

validate_config() {
    [[ "$AUTO_ENABLED" =~ ^[01]$ ]] || die "AUTO_ENABLED должен быть 0 или 1"
    [[ "$MANUAL_FAN" =~ ^[0-9]+$ ]] && (( MANUAL_FAN >= 0 && MANUAL_FAN <= 100 )) || die "MANUAL_FAN должен быть 0..100"
    [[ "$TARGET_TEMP" =~ ^[0-9]+$ ]] && (( TARGET_TEMP >= 1 && TARGET_TEMP <= 110 )) || die "TARGET_TEMP должен быть 1..110"
    [[ "$TARGET_MEM_TEMP" =~ ^[0-9]+$ ]] && (( TARGET_MEM_TEMP >= 1 && TARGET_MEM_TEMP <= 120 )) || die "TARGET_MEM_TEMP должен быть 1..120"
    [[ "$WATCHDOG" =~ ^[01]$ ]] || die "WATCHDOG должен быть 0 или 1"
    [[ "$WD_RESET_INTERVAL" =~ ^[0-9]+$ ]] && (( WD_RESET_INTERVAL >= 1 && WD_RESET_INTERVAL <= 60 )) || die "WD_RESET_INTERVAL должен быть 1..60"
}

prepare_runtime() {
    install -d -m 0755 "$RUNTIME_DIR"
    [[ -e "$SERIAL_PORT" ]] || die "Не найден последовательный порт: $SERIAL_PORT"
    require_cmd stty
    require_cmd jq
    require_cmd flock
}

start_listener() {
    prepare_runtime
    if [[ -f "$LISTENER_PID_FILE" ]] && kill -0 "$(cat "$LISTENER_PID_FILE")" 2>/dev/null; then
        return 0
    fi
    rm -f "$LISTENER_PID_FILE"
    # A single persistent reader prevents each command from reopening the port
    # just to receive data. The controller sends newline-terminated JSON.
    nohup bash -c '
        port="$1"; outfile="$2"
        stty -F "$port" raw ispeed 9600 ospeed 9600 -ignpar cs8 -cstopb -echo || exit 1
        exec cat "$port" >> "$outfile"
    ' _ "$SERIAL_PORT" "$REPLY_FILE" </dev/null >/dev/null 2>&1 &
    echo $! > "$LISTENER_PID_FILE"
    sleep 0.3
    kill -0 "$(cat "$LISTENER_PID_FILE")" 2>/dev/null || die "Не удалось запустить чтение порта"
}

stop_listener() {
    if [[ -f "$LISTENER_PID_FILE" ]]; then
        local pid
        pid="$(cat "$LISTENER_PID_FILE")"
        kill "$pid" 2>/dev/null || true
        rm -f "$LISTENER_PID_FILE"
    fi
}

send_request() {
    local payload="$1" before after answer
    prepare_runtime
    start_listener
    # Serialize requests so two CLI calls cannot steal each other's responses.
    exec 9>"$LOCK_FILE"
    flock -x 9
    before="$(wc -l < "$REPLY_FILE" 2>/dev/null || echo 0)"
    printf '%s\n' "$payload" > "$SERIAL_PORT" || die "Не удалось отправить команду в $SERIAL_PORT"
    local deadline=$((SECONDS + 2))
    answer=""
    while (( SECONDS <= deadline )); do
        after="$(wc -l < "$REPLY_FILE" 2>/dev/null || echo 0)"
        if (( after > before )); then
            answer="$(tail -n "$((after - before))" "$REPLY_FILE" | grep -E '^\s*\{.*\}\s*$' | tail -n 1 || true)"
            if [[ -n "$answer" ]]; then
                printf '%s\n' "$answer"
                return 0
            fi
        fi
        sleep 0.1
    done
    printf '{}\n'
    return 1
}

get_serial() {
    if command -v lsusb >/dev/null 2>&1; then
        lsusb -v -d 10c4:ea60 2>/dev/null | awk -F': ' '/iSerial/ {print $2; exit}'
    else
        printf 'lsusb не установлен\n' >&2
        return 1
    fi
}

diagnostic() {
    local i answer
    for i in {1..5}; do
        answer="$(send_request '{"diagnostic"}' 2>/dev/null || true)"
        if jq -e '.mcu_version and .pcb_version and .fw_version' >/dev/null 2>&1 <<<"$answer"; then
            jq . <<<"$answer"
            return 0
        fi
        sleep 0.2
    done
    die "Контроллер не ответил на diagnostic. Проверьте порт и подключение."
}

fan_check() {
    local i answer
    for i in {1..10}; do
        answer="$(send_request '{"fan_check"}' 2>/dev/null || true)"
        if jq -e '.message? | strings | test("fan check"; "i")' >/dev/null 2>&1 <<<"$answer"; then
            jq -r '.message' <<<"$answer"
            return 0
        fi
        sleep 0.2
    done
    die "Контроллер не вернул подтверждение fan_check."
}

send_message() {
    [[ $# -ge 1 ]] || die "Использование: $0 --msg 'текст'"
    local msg="$*"
    jq -n --arg message "$msg" '{message:$message}' | {
        read -r payload
        send_request "$payload"
    }
}

get_gpu_arrays() {
    # The controller API accepts arrays. On Ubuntu, use detected GPU data when
    # supported; otherwise send empty arrays rather than fabricate temperatures.
    local temps='[]' mems='[]'
    if command -v nvidia-smi >/dev/null 2>&1; then
        temps="$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | awk 'NF {printf "%s%s", sep, $1; sep=","}' | sed 's/^/[/' | sed 's/$/]/')"
        mems="$(nvidia-smi --query-gpu=temperature.memory --format=csv,noheader,nounits 2>/dev/null | awk 'NF && $1 ~ /^[0-9]+$/ {printf "%s%s", sep, $1; sep=","}' | sed 's/^/[/' | sed 's/$/]/')"
        [[ -n "$temps" ]] || temps='[]'
        [[ -n "$mems" ]] || mems='[]'
    elif command -v rocm-smi >/dev/null 2>&1; then
        # ROCm output varies between versions; parse per-GPU edge temperature
        # from the plain-text table if present.
        local raw
        raw="$(rocm-smi --showtemp 2>/dev/null || true)"
        temps="$(awk '/Temperature \(Sensor edge\)/ {gsub(/[^0-9.]/,"",$NF); if ($NF!="") printf "%s%s", sep, int($NF); sep=","}' <<<"$raw" | sed 's/^/[/' | sed 's/$/]/')"
        [[ -n "$temps" ]] || temps='[]'
        mems='[]'
    fi
    jq -cn --argjson t "$temps" --argjson m "$mems" '{gpu_temp:$t,gpu_mem:$m}'
}

get_stats() {
    load_config
    validate_config
    local gpu_json request
    gpu_json="$(get_gpu_arrays)"
    local gpu_temp gpu_mem
    gpu_temp="$(jq -c '.gpu_temp' <<<"$gpu_json")"
    gpu_mem="$(jq -c '.gpu_mem' <<<"$gpu_json")"
    local fan_mode=1
    (( AUTO_ENABLED == 1 )) && fan_mode=2
    request="$(jq -cn \
        --argjson gpu_temp "$gpu_temp" \
        --argjson gpu_mem "$gpu_mem" \
        --argjson target_temp "$TARGET_TEMP" \
        --argjson target_mem "$TARGET_MEM_TEMP" \
        --argjson manual_fan "$MANUAL_FAN" \
        --argjson fan_mode "$fan_mode" \
        --argjson watchdog "$WATCHDOG" \
        --argjson interval "$WD_RESET_INTERVAL" \
        '{gpu_temp:$gpu_temp,gpu_mem:$gpu_mem,target_temp:$target_temp,target_mem:$target_mem,manual_fan_speed:$manual_fan,fan_mode:$fan_mode,watchdog:$watchdog,wd_reset_interval:$interval}')"
    send_request "$request"
}

get_json() {
    local i answer
    for i in {1..10}; do
        answer="$(get_stats 2>/dev/null || true)"
        if jq -e 'type == "object" and (has("thermosensors") or has("fan_mode") or has("message"))' >/dev/null 2>&1 <<<"$answer"; then
            jq . <<<"$answer"
            return 0
        fi
        sleep 0.2
    done
    printf '{}\n'
    return 1
}

set_value() {
    local key="$1" value="$2"
    load_config
    case "$key" in
        auto)
            [[ "$value" =~ ^[01]$ ]] || die "Значение auto: 0 (ручной режим) или 1 (авто)"
            AUTO_ENABLED="$value" ;;
        fan)
            [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 0 && value <= 100 )) || die "Скорость вентилятора должна быть 0..100"
            MANUAL_FAN="$value" ;;
        temp)
            [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 110 )) || die "Целевая температура должна быть 1..110"
            TARGET_TEMP="$value" ;;
        memtemp)
            [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 120 )) || die "Целевая температура памяти должна быть 1..120"
            TARGET_MEM_TEMP="$value" ;;
        watchdog)
            [[ "$value" =~ ^[01]$ ]] || die "watchdog: 0 или 1"
            WATCHDOG="$value" ;;
        interval)
            [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 60 )) || die "Интервал watchdog должен быть 1..60"
            WD_RESET_INTERVAL="$value" ;;
        *) die "Неизвестная настройка: $key" ;;
    esac
    validate_config
    save_config
    log "${GREEN}Сохранено:${RESET} $key=$value в $CONFIG_FILE"
}

show_config() {
    load_config
    printf 'Режим: %s\n' "$([[ "$AUTO_ENABLED" == 1 ]] && echo Авто || echo Ручной)"
    printf 'Скорость вентилятора: %s%%\nЦелевая температура GPU: %s°C\nЦелевая температура памяти: %s°C\nWatchdog: %s\nИнтервал watchdog: %s\n' \
        "$MANUAL_FAN" "$TARGET_TEMP" "$TARGET_MEM_TEMP" "$WATCHDOG" "$WD_RESET_INTERVAL"
    printf 'Конфиг: %s\nПорт: %s\n' "$CONFIG_FILE" "$SERIAL_PORT"
}

show_help() {
    cat <<EOF
CoolBox AutoFan PRO для Ubuntu (без обновления прошивки)

Использование:
  $0 --diagnostic            Диагностика контроллера
  $0 --get_serial            Серийный номер USB-устройства
  $0 --get_json              Запрос текущих данных и применение настроек
  $0 --fan_check             Проверка вентиляторов (если поддерживается прошивкой)
  $0 --msg 'текст'           Отправить текстовое сообщение
  $0 --config                Показать локальные настройки
  $0 --set auto 0|1          0=ручной режим, 1=автоматический режим
  $0 --set fan 0..100        Скорость в ручном режиме, %
  $0 --set temp 1..110       Целевая температура GPU, °C
  $0 --set memtemp 1..120    Целевая температура памяти, °C
  $0 --set watchdog 0|1      Выключить/включить watchdog
  $0 --set interval 1..60    Интервал watchdog
  $0 --help                  Эта справка

Настройки хранятся в $CONFIG_FILE.
Порт по умолчанию: $SERIAL_PORT (можно изменить через COOLBOX_SERIAL_PORT).
Обновление прошивки и команды остановки/запуска майнера в этой версии отсутствуют.
EOF
}

main() {
    require_cmd jq
    load_config
    case "${1:---get_json}" in
        --get_json) get_json ;;
        --get_serial) get_serial ;;
        --diagnostic) diagnostic ;;
        --fan_check) fan_check ;;
        --msg) shift; send_message "$@" ;;
        --config) show_config ;;
        --set)
            [[ $# -eq 3 ]] || die "Использование: $0 --set auto|fan|temp|memtemp|watchdog|interval значение"
            set_value "$2" "$3" ;;
        --stop-listener) stop_listener ;;
        --help|-h) show_help ;;
        *) die "Неизвестная команда '$1'. Используйте --help." ;;
    esac
}

main "$@"
