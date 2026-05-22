#!/bin/zsh

set +e

OWNER="GiroGinx992"
REPO="installer"

BASE_DIR="$HOME/Library/Application Support/OnboardingInstaller"
DOWNLOAD_DIR="$BASE_DIR/downloads"
LOG_DIR="$HOME/Library/Logs/OnboardingInstaller"
LOG_FILE="$LOG_DIR/install-macos.log"

mkdir -p "$DOWNLOAD_DIR"
mkdir -p "$LOG_DIR"

write_log() {
    local message="$1"
    local level="${2:-INFO}"
    local time
    time="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$time] [$level] $message" | tee -a "$LOG_FILE"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_requirements() {
    write_log "Проверяю зависимости"

    if ! command_exists curl; then
        write_log "curl не найден" "ERROR"
        exit 1
    fi

    if ! command_exists python3; then
        write_log "python3 не найден. Установи Command Line Tools: xcode-select --install" "ERROR"
        exit 1
    fi
}

get_release_json() {
    local url="https://api.github.com/repos/$OWNER/$REPO/releases/latest"
    local output="$BASE_DIR/release.json"

    write_log "Получаю GitHub Release: $url"

    for attempt in 1 2 3 4 5; do
        write_log "Попытка $attempt"

        curl -L \
            -H "User-Agent: OnboardingInstaller-macOS" \
            -H "Accept: application/vnd.github+json" \
            --connect-timeout 30 \
            --max-time 120 \
            -o "$output" \
            "$url"

        if [ $? -eq 0 ] && [ -s "$output" ]; then
            if grep -q '"assets"' "$output"; then
                write_log "Release получен"
                echo "$output"
                return 0
            fi
        fi

        write_log "Не удалось получить Release. Жду 5 секунд..." "WARN"
        sleep 5
    done

    write_log "Не удалось получить GitHub Release" "ERROR"
    exit 1
}

get_asset_url() {
    local release_json="$1"
    local pattern="$2"

    python3 - "$release_json" "$pattern" <<'PY'
import json
import re
import sys

path = sys.argv[1]
pattern = sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

for asset in data.get("assets", []):
    name = asset.get("name", "")
    if re.search(pattern, name):
        print(asset.get("browser_download_url", ""))
        sys.exit(0)

sys.exit(1)
PY
}

get_asset_name() {
    local release_json="$1"
    local pattern="$2"

    python3 - "$release_json" "$pattern" <<'PY'
import json
import re
import sys

path = sys.argv[1]
pattern = sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

for asset in data.get("assets", []):
    name = asset.get("name", "")
    if re.search(pattern, name):
        print(name)
        sys.exit(0)

sys.exit(1)
PY
}

download_asset() {
    local release_json="$1"
    local pattern="$2"

    local url
    local name
    local output

    url="$(get_asset_url "$release_json" "$pattern")"
    name="$(get_asset_name "$release_json" "$pattern")"

    if [ -z "$url" ] || [ -z "$name" ]; then
        write_log "Asset не найден по шаблону: $pattern" "WARN"
        return 1
    fi

    output="$DOWNLOAD_DIR/$name"

    if [ -f "$output" ]; then
        write_log "Файл уже скачан: $output"
        echo "$output"
        return 0
    fi

    write_log "Скачиваю: $name"
    write_log "URL: $url"

    curl -L \
        -H "User-Agent: OnboardingInstaller-macOS" \
        --connect-timeout 30 \
        --max-time 0 \
        -o "$output" \
        "$url"

    if [ $? -ne 0 ]; then
        write_log "Ошибка скачивания: $name" "ERROR"
        return 1
    fi

    write_log "Скачано: $output"
    echo "$output"
    return 0
}

install_dmg() {
    local dmg_path="$1"
    local app_name="$2"

    write_log "Монтирую DMG: $dmg_path"

    local mount_info
    local mount_point

    mount_info="$(hdiutil attach "$dmg_path" -nobrowse -quiet 2>&1)"
    mount_point="$(echo "$mount_info" | grep -o '/Volumes/.*' | head -n 1)"

    if [ -z "$mount_point" ]; then
        mount_point="$(hdiutil info | grep "/Volumes/" | tail -n 1 | awk '{$1=$2=$3=""; print substr($0,4)}')"
    fi

    if [ -z "$mount_point" ] || [ ! -d "$mount_point" ]; then
        write_log "Не удалось определить точку монтирования для $dmg_path" "ERROR"
        return 1
    fi

    write_log "DMG смонтирован: $mount_point"

    local pkg_file
    local app_file

    pkg_file="$(find "$mount_point" -maxdepth 3 -name "*.pkg" -type f | head -n 1)"
    app_file="$(find "$mount_point" -maxdepth 3 -name "*.app" -type d | head -n 1)"

    if [ -n "$pkg_file" ]; then
        write_log "Найден PKG: $pkg_file"
        sudo installer -pkg "$pkg_file" -target /
        local code=$?

        hdiutil detach "$mount_point" -quiet

        if [ $code -eq 0 ]; then
            write_log "Установлено через PKG: $app_name"
        else
            write_log "Ошибка установки PKG: $app_name" "ERROR"
        fi

        return $code
    fi

    if [ -n "$app_file" ]; then
        local target="/Applications/$(basename "$app_file")"

        write_log "Найдено приложение: $app_file"
        write_log "Копирую в: $target"

        if [ -d "$target" ]; then
            write_log "Удаляю старую версию: $target"
            sudo rm -rf "$target"
        fi

        sudo cp -R "$app_file" "/Applications/"
        local code=$?

        hdiutil detach "$mount_point" -quiet

        if [ $code -eq 0 ]; then
            write_log "Установлено приложение: $app_name"
        else
            write_log "Ошибка копирования приложения: $app_name" "ERROR"
        fi

        return $code
    fi

    write_log "В DMG не найдено .app или .pkg: $dmg_path" "ERROR"
    hdiutil detach "$mount_point" -quiet
    return 1
}

install_zip_app() {
    local zip_path="$1"
    local app_name="$2"

    local extract_dir="$DOWNLOAD_DIR/extracted-$app_name"

    write_log "Распаковываю ZIP: $zip_path"

    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    unzip -q "$zip_path" -d "$extract_dir"

    local app_file
    app_file="$(find "$extract_dir" -maxdepth 3 -name "*.app" -type d | head -n 1)"

    if [ -z "$app_file" ]; then
        write_log "В ZIP не найдено .app: $zip_path" "ERROR"
        return 1
    fi

    local target="/Applications/$(basename "$app_file")"

    if [ -d "$target" ]; then
        write_log "Удаляю старую версию: $target"
        sudo rm -rf "$target"
    fi

    write_log "Копирую $app_file в /Applications"

    sudo cp -R "$app_file" "/Applications/"
    local code=$?

    if [ $code -eq 0 ]; then
        write_log "Установлено приложение: $app_name"
    else
        write_log "Ошибка установки приложения: $app_name" "ERROR"
    fi

    return $code
}

write_log "=== Старт установки onboarding ПО для macOS ==="

check_requirements

RELEASE_JSON="$(get_release_json)"

write_log "Release JSON: $RELEASE_JSON"

# Docker Desktop
DOCKER_DMG="$(download_asset "$RELEASE_JSON" "Docker\.dmg$")"
if [ -n "$DOCKER_DMG" ] && [ -f "$DOCKER_DMG" ]; then
    install_dmg "$DOCKER_DMG" "Docker Desktop"
fi

# FortiClient
FORTI_DMG="$(download_asset "$RELEASE_JSON" "FortiClient.*\.dmg$")"
if [ -n "$FORTI_DMG" ] && [ -f "$FORTI_DMG" ]; then
    install_dmg "$FORTI_DMG" "FortiClient"
fi

# Freelens
FREELENS_DMG="$(download_asset "$RELEASE_JSON" "Freelens-.*macos.*\.dmg$")"
if [ -n "$FREELENS_DMG" ] && [ -f "$FREELENS_DMG" ]; then
    install_dmg "$FREELENS_DMG" "Freelens"
fi

# KeePassXC
KEEPASS_DMG="$(download_asset "$RELEASE_JSON" "KeePassXC-.*\.dmg$")"
if [ -n "$KEEPASS_DMG" ] && [ -f "$KEEPASS_DMG" ]; then
    install_dmg "$KEEPASS_DMG" "KeePassXC"
fi

# Postman
POSTMAN_ZIP="$(download_asset "$RELEASE_JSON" "Postman.*macOS.*\.zip$")"
if [ -n "$POSTMAN_ZIP" ] && [ -f "$POSTMAN_ZIP" ]; then
    install_zip_app "$POSTMAN_ZIP" "Postman"
fi

# Slack
SLACK_DMG="$(download_asset "$RELEASE_JSON" "Slack-.*macOS.*\.dmg$")"
if [ -n "$SLACK_DMG" ] && [ -f "$SLACK_DMG" ]; then
    install_dmg "$SLACK_DMG" "Slack"
fi

write_log "=== Установка завершена ==="
write_log "Лог: $LOG_FILE"

echo ""
echo "Готово."
echo "Лог установки:"
echo "$LOG_FILE"
