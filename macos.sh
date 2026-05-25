#!/bin/zsh

# Назначение:
# Скачать установщики из GitHub Release и установить программы на macOS.
#
# Repo:
# https://github.com/GiroGinx992/installer
#
# Запуск:
# /bin/zsh -c "$(curl -fsSL https://raw.githubusercontent.com/GiroGinx992/installer/main/install/macos.sh)"

set +e

OWNER="GiroGinx992"
REPO="installer"

# true = брать latest release
# false = брать конкретный RELEASE_TAG
USE_LATEST_RELEASE=true

# ВАЖНО:
# У тебя tag в ссылках был onbording-v1, без буквы "a" после bo.
# Если включишь USE_LATEST_RELEASE=false, используй реальный tag.
RELEASE_TAG="onbording-v1"

BASE_DIR="$HOME/Library/Application Support/OnboardingInstaller"
DOWNLOAD_DIR="$BASE_DIR/downloads"
EXTRACT_DIR="$BASE_DIR/extracted"
LOG_DIR="$HOME/Library/Logs/OnboardingInstaller"
LOG_FILE="$LOG_DIR/install-macos.log"
RELEASE_JSON_FILE="$BASE_DIR/release.json"

mkdir -p "$BASE_DIR"
mkdir -p "$DOWNLOAD_DIR"
mkdir -p "$EXTRACT_DIR"
mkdir -p "$LOG_DIR"

write_log() {
    local message="$1"
    local level="${2:-INFO}"
    local time
    time="$(date '+%Y-%m-%d %H:%M:%S')"

    # Пишем в stderr, чтобы логи не попадали в release.json
    echo "[$time] [$level] $message" | tee -a "$LOG_FILE" >&2
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_requirements() {
    write_log "Проверяю системные команды..."

    local missing=0

    for cmd in curl python3 hdiutil installer find du awk grep sed sw_vers unzip; do
        if ! command_exists "$cmd"; then
            write_log "Не найдена команда: $cmd" "ERROR"
            missing=1
        fi
    done

    if [[ "$missing" -eq 1 ]]; then
        write_log "Не хватает системных команд. Остановка." "ERROR"
        exit 1
    fi
}

get_release_json() {
    local url

    if [[ "$USE_LATEST_RELEASE" == true ]]; then
        url="https://api.github.com/repos/$OWNER/$REPO/releases/latest"
    else
        url="https://api.github.com/repos/$OWNER/$REPO/releases/tags/$RELEASE_TAG"
    fi

    write_log "Получаю GitHub Release: $url"

    curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "User-Agent: OnboardingInstaller" \
        "$url"
}

validate_json_file() {
    local json_file="$1"

    python3 - "$json_file" <<'PY'
import json
import sys

path = sys.argv[1]

try:
    with open(path, "r", encoding="utf-8") as f:
        json.load(f)
except Exception as e:
    print(f"JSON_ERROR: {e}")
    sys.exit(1)

sys.exit(0)
PY
}

print_release_assets() {
    local json_file="$1"

    python3 - "$json_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

print("Release:", data.get("name"))
print("Tag:", data.get("tag_name"))
print("All assets:")

for asset in data.get("assets", []):
    print(" - " + asset.get("name", ""))
PY
}

print_macos_assets() {
    local json_file="$1"

    python3 - "$json_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

print("macOS-compatible assets:")

found = False

for asset in data.get("assets", []):
    name = asset.get("name", "")
    lower = name.lower()

    if lower.endswith((".dmg", ".pkg", ".zip")):
        print(" - " + name)
        found = True

if not found:
    print(" - macOS assets not found")
PY
}

find_asset_field() {
    local json_file="$1"
    local field="$2"
    shift 2

    python3 - "$json_file" "$field" "$@" <<'PY'
import json
import sys

json_file = sys.argv[1]
field = sys.argv[2]
patterns = [x.lower() for x in sys.argv[3:] if x.strip()]

allowed_extensions = (".dmg", ".pkg", ".zip")

with open(json_file, "r", encoding="utf-8") as f:
    data = json.load(f)

assets = data.get("assets", [])

# Сначала ищем точные совпадения по переданным паттернам
for asset in assets:
    name = asset.get("name", "")
    lower_name = name.lower()

    if not lower_name.endswith(allowed_extensions):
        continue

    for pattern in patterns:
        if pattern in lower_name:
            print(asset.get(field, ""))
            sys.exit(0)

sys.exit(1)
PY
}

download_file() {
    local url="$1"
    local output="$2"

    write_log "Скачиваю: $url"
    write_log "Куда: $output"

    rm -f "$output"

    curl -L --fail --progress-bar -o "$output" "$url"

    if [[ $? -ne 0 ]]; then
        write_log "Ошибка скачивания: $url" "ERROR"
        return 1
    fi

    if [[ ! -s "$output" ]]; then
        write_log "Файл не скачался или размер 0: $output" "ERROR"
        return 1
    fi

    local size
    size="$(du -h "$output" | awk '{print $1}')"
    write_log "Файл скачан: $output ($size)"

    return 0
}

install_pkg() {
    local pkg_path="$1"

    write_log "Устанавливаю PKG: $pkg_path"

    sudo installer -pkg "$pkg_path" -target /

    local code=$?

    if [[ "$code" -eq 0 ]]; then
        write_log "PKG установлен успешно."
        return 0
    else
        write_log "Ошибка установки PKG: $pkg_path. Exit code: $code" "ERROR"
        return 1
    fi
}

copy_app_to_applications() {
    local app_path="$1"
    local app_name
    app_name="$(basename "$app_path")"

    local destination="/Applications/$app_name"

    write_log "Копирую APP: $app_path"
    write_log "Назначение: $destination"

    if [[ -d "$destination" ]]; then
        write_log "Приложение уже есть, удаляю старую версию: $destination"
        sudo rm -rf "$destination"
    fi

    sudo cp -R "$app_path" "/Applications/"

    local code=$?

    if [[ "$code" -eq 0 ]]; then
        write_log "APP скопирован в /Applications: $app_name"
        return 0
    else
        write_log "Ошибка копирования APP: $app_name. Exit code: $code" "ERROR"
        return 1
    fi
}

detach_dmg() {
    local volume_path="$1"

    if [[ -n "$volume_path" ]]; then
        write_log "Отмонтирую DMG: $volume_path"
        hdiutil detach "$volume_path" -quiet

        if [[ $? -ne 0 ]]; then
            write_log "Обычное отмонтирование не удалось, пробую force: $volume_path" "WARN"
            hdiutil detach "$volume_path" -force -quiet
        fi
    fi
}

install_dmg() {
    local dmg_path="$1"

    write_log "Монтирую DMG: $dmg_path"

    local attach_output
    attach_output="$(hdiutil attach "$dmg_path" -nobrowse 2>&1)"
    local attach_code=$?

    echo "$attach_output" | tee -a "$LOG_FILE" >&2

    if [[ "$attach_code" -ne 0 ]]; then
        write_log "Ошибка монтирования DMG: $dmg_path" "ERROR"
        return 1
    fi

    local volume_path
    volume_path="$(echo "$attach_output" | awk '/\/Volumes\// {for (i=1;i<=NF;i++) if ($i ~ /^\/Volumes\//) print $i}' | tail -n 1)"

    if [[ -z "$volume_path" ]]; then
        write_log "Не удалось определить /Volumes путь для DMG." "ERROR"
        return 1
    fi

    write_log "DMG смонтирован: $volume_path"

    local pkg_path
    local app_path

    pkg_path="$(find "$volume_path" \
        -path "*/__MACOSX/*" -prune -o \
        -maxdepth 6 \
        -name "*.pkg" \
        -print -quit 2>/dev/null)"

    app_path="$(find "$volume_path" \
        -path "*/__MACOSX/*" -prune -o \
        -maxdepth 6 \
        -name "*.app" \
        -print -quit 2>/dev/null)"

    local result=1

    if [[ -n "$pkg_path" ]]; then
        write_log "Найден PKG внутри DMG: $pkg_path"
        install_pkg "$pkg_path"
        result=$?
    elif [[ -n "$app_path" ]]; then
        write_log "Найден APP внутри DMG: $app_path"

        local app_base_name
        app_base_name="$(basename "$app_path")"

        # Forti online installer часто является не готовым приложением, а GUI-загрузчиком.
        # Скрипт может скопировать .app, но это не равно полноценной silent-установке FortiVPN.
        if echo "$app_base_name" | grep -qi "forti"; then
            write_log "Обнаружен Forti .app внутри DMG: $app_base_name" "WARN"
            write_log "Если это OnlineInstaller, он может требовать ручной GUI-запуск." "WARN"
        fi

        copy_app_to_applications "$app_path"
        result=$?
    else
        write_log "В DMG не найден .pkg или .app" "ERROR"
        result=1
    fi

    detach_dmg "$volume_path"

    return $result
}

install_zip() {
    local zip_path="$1"
    local name_without_ext
    name_without_ext="$(basename "$zip_path" .zip)"

    local extract_path="$EXTRACT_DIR/$name_without_ext"

    write_log "Распаковываю ZIP: $zip_path"
    write_log "Куда: $extract_path"

    rm -rf "$extract_path"
    mkdir -p "$extract_path"

    unzip -q "$zip_path" -d "$extract_path"

    if [[ $? -ne 0 ]]; then
        write_log "Ошибка распаковки ZIP: $zip_path" "ERROR"
        return 1
    fi

    local pkg_path
    local app_path

    # ВАЖНО:
    # Игнорируем __MACOSX, потому что это служебная папка архива.
    pkg_path="$(find "$extract_path" \
        -path "*/__MACOSX/*" -prune -o \
        -name "*.pkg" \
        -print -quit 2>/dev/null)"

    app_path="$(find "$extract_path" \
        -path "*/__MACOSX/*" -prune -o \
        -name "*.app" \
        -print -quit 2>/dev/null)"

    if [[ -n "$pkg_path" ]]; then
        write_log "Найден PKG внутри ZIP: $pkg_path"
        install_pkg "$pkg_path"
        return $?
    elif [[ -n "$app_path" ]]; then
        write_log "Найден APP внутри ZIP: $app_path"
        copy_app_to_applications "$app_path"
        return $?
    else
        write_log "В ZIP не найден нормальный .pkg или .app, кроме __MACOSX" "ERROR"
        return 1
    fi
}

install_downloaded_file() {
    local file_path="$1"

    case "$file_path" in
        *.pkg|*.PKG)
            install_pkg "$file_path"
            return $?
            ;;
        *.dmg|*.DMG)
            install_dmg "$file_path"
            return $?
            ;;
        *.zip|*.ZIP)
            install_zip "$file_path"
            return $?
            ;;
        *)
            write_log "Неподдерживаемый формат: $file_path" "ERROR"
            return 1
            ;;
    esac
}

install_program_from_release() {
    local display_name="$1"
    shift

    write_log "----------------------------------------"
    write_log "Проверяю программу: $display_name"

    local asset_url
    local asset_name

    asset_url="$(find_asset_field "$RELEASE_JSON_FILE" "browser_download_url" "$@" 2>>"$LOG_FILE")"
    asset_name="$(find_asset_field "$RELEASE_JSON_FILE" "name" "$@" 2>>"$LOG_FILE")"

    if [[ -z "$asset_url" || -z "$asset_name" ]]; then
        write_log "Файл для $display_name не найден в release. Поиск: $*" "WARN"
        return 0
    fi

    write_log "Найден asset: $asset_name"

    local target_path="$DOWNLOAD_DIR/$asset_name"

    download_file "$asset_url" "$target_path"

    if [[ $? -ne 0 ]]; then
        write_log "Пропускаю $display_name из-за ошибки скачивания." "ERROR"
        return 1
    fi

    install_downloaded_file "$target_path"

    local install_code=$?

    if [[ "$install_code" -eq 0 ]]; then
        write_log "Готово: $display_name"
    else
        write_log "Установка завершилась с ошибкой: $display_name" "ERROR"
    fi

    return $install_code
}

write_log "=== Старт macOS onboarding install ==="

check_requirements

MACOS_VERSION="$(sw_vers -productVersion)"
write_log "macOS version: $MACOS_VERSION"

write_log "Очищаю старый release.json"
rm -f "$RELEASE_JSON_FILE"

get_release_json > "$RELEASE_JSON_FILE"
release_code=$?

if [[ "$release_code" -ne 0 ]]; then
    write_log "Не удалось получить GitHub Release JSON. curl exit code: $release_code" "ERROR"
    exit 1
fi

if [[ ! -s "$RELEASE_JSON_FILE" ]]; then
    write_log "release.json пустой: $RELEASE_JSON_FILE" "ERROR"
    exit 1
fi

validate_json_file "$RELEASE_JSON_FILE" >/tmp/onboarding_json_check.txt 2>&1

if [[ $? -ne 0 ]]; then
    write_log "release.json поврежден или не является JSON." "ERROR"
    write_log "Первые 10 строк release.json:" "ERROR"
    head -n 10 "$RELEASE_JSON_FILE" | tee -a "$LOG_FILE" >&2
    write_log "Ошибка проверки JSON:" "ERROR"
    cat /tmp/onboarding_json_check.txt | tee -a "$LOG_FILE" >&2
    exit 1
fi

write_log "Release JSON получен и проверен: $RELEASE_JSON_FILE"

write_log "Все файлы в release:"
print_release_assets "$RELEASE_JSON_FILE" | tee -a "$LOG_FILE" >&2

write_log "macOS-файлы в release:"
print_macos_assets "$RELEASE_JSON_FILE" | tee -a "$LOG_FILE" >&2

# =========================
# Установка программ
# =========================

install_program_from_release "Docker Desktop" \
    "docker" \
    "docker desktop"

install_program_from_release "FortiClient VPN" \
    "forticlient" \
    "forticlientvpn" \
    "forticlient_vpn" \
    "forticlient-vpn" \
    "forti"

install_program_from_release "OpenVPN Connect" \
    "openvpn" \
    "openvpnconnect" \
    "openvpn_connect" \
    "openvpn-connect" \
    "open vpn" \
    "open-vpn"

install_program_from_release "KeePassXC" \
    "keepass" \
    "keepassxc"

install_program_from_release "Slack" \
    "slack"

install_program_from_release "Postman" \
    "postman"

install_program_from_release "Telegram" \
    "telegram" \
    "tdesktop" \
    "telegram-desktop" \
    "telegramdesktop" \
    "telegram for macos" \
    "telegram-macos"

install_program_from_release "Yandex Telemost" \
    "telemost" \
    "yandextelemost" \
    "yandex-telemost" \
    "yandex_telemost" \
    "yandex telemost" \
    "яндекс" \
    "телемост"

install_program_from_release "Microsoft Office" \
    "microsoft office" \
    "microsoft_office" \
    "microsoft-office" \
    "office" \
    "microsoft_365" \
    "microsoft-365" \
    "m365" \
    "office365"

write_log "=== macOS onboarding install завершен ==="
write_log "Лог: $LOG_FILE"
