#!/bin/zsh

set +e

OWNER="GiroGinx992"
REPO="installer"

BASE_DIR="$HOME/Library/Application Support/OnboardingInstaller"
DOWNLOAD_DIR="$BASE_DIR/downloads"
LOG_DIR="$HOME/Library/Logs/OnboardingInstaller"
LOG_FILE="$LOG_DIR/install-macos.log"
RELEASE_JSON="$BASE_DIR/release.json"

mkdir -p "$DOWNLOAD_DIR"
mkdir -p "$LOG_DIR"

write_log() {
    local message="$1"
    local level="${2:-INFO}"
    local time
    time="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$time] [$level] $message" | tee -a "$LOG_FILE" >&2
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_requirements() {
    write_log "Проверяю стандартные зависимости macOS"

    local missing=0

    for cmd in curl grep sed awk tr hdiutil unzip ditto find; do
        if ! command_exists "$cmd"; then
            write_log "Не найдена команда: $cmd" "ERROR"
            missing=1
        fi
    done

    if [ "$missing" -eq 1 ]; then
        write_log "Не хватает стандартных утилит macOS. Установка остановлена." "ERROR"
        exit 1
    fi

    write_log "Все базовые зависимости найдены"
}

get_release_json() {
    local url="https://api.github.com/repos/$OWNER/$REPO/releases/latest"

    write_log "Получаю latest GitHub Release"
    write_log "URL: $url"

    for attempt in 1 2 3 4 5; do
        write_log "Попытка получения Release: $attempt"

        curl -L \
            -H "User-Agent: OnboardingInstaller-macOS" \
            -H "Accept: application/vnd.github+json" \
            --connect-timeout 30 \
            --max-time 120 \
            -o "$RELEASE_JSON" \
            "$url"

        if [ $? -eq 0 ] && [ -s "$RELEASE_JSON" ]; then
            if grep -q '"assets"' "$RELEASE_JSON"; then
                write_log "GitHub Release успешно получен"
                return 0
            fi
        fi

        write_log "Не удалось получить Release. Жду 5 секунд..." "WARN"
        sleep 5
    done

    write_log "Не удалось получить GitHub Release после 5 попыток" "ERROR"
    return 1
}

show_assets() {
    write_log "Список файлов в GitHub Release:"

    grep '"name"[[:space:]]*:' "$RELEASE_JSON" \
        | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
        | while read -r asset_name; do
            write_log "Asset: $asset_name"
        done
}

get_asset_url_by_pattern() {
    local pattern="$1"
    local lower_pattern
    lower_pattern="$(printf "%s" "$pattern" | tr '[:upper:]' '[:lower:]')"

    grep '"browser_download_url"[[:space:]]*:' "$RELEASE_JSON" \
        | sed -E 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
        | while read -r url; do
            local lower_url
            lower_url="$(printf "%s" "$url" | tr '[:upper:]' '[:lower:]')"

            if [[ "$lower_url" =~ "$lower_pattern" ]]; then
                echo "$url"
                return 0
            fi
        done
}

get_filename_from_url() {
    local url="$1"
    local file

    file="${url##*/}"
    file="$(printf "%s" "$file" | sed 's/%20/ /g')"

    echo "$file"
}

download_url_to_file() {
    local url="$1"
    local output="$2"
    local title="$3"

    if [ -f "$output" ] && [ -s "$output" ]; then
        write_log "Файл уже скачан: $output"
        echo "$output"
        return 0
    fi

    write_log "Скачиваю: $title"
    write_log "URL: $url"

    curl -L \
        -H "User-Agent: OnboardingInstaller-macOS" \
        --connect-timeout 30 \
        --max-time 0 \
        --retry 3 \
        --retry-delay 5 \
        -o "$output" \
        "$url"

    if [ $? -ne 0 ] || [ ! -s "$output" ]; then
        write_log "Ошибка скачивания: $title" "ERROR"
        rm -f "$output"
        return 1
    fi

    write_log "Файл скачан: $output"
    echo "$output"
    return 0
}

download_asset() {
    local pattern="$1"
    local app_title="$2"

    local url
    local filename
    local output

    write_log "Ищу asset для: $app_title"
    write_log "Шаблон: $pattern"

    url="$(get_asset_url_by_pattern "$pattern")"

    if [ -z "$url" ]; then
        write_log "Asset не найден: $app_title" "WARN"
        return 1
    fi

    filename="$(get_filename_from_url "$url")"
    output="$DOWNLOAD_DIR/$filename"

    write_log "Найден asset: $filename"

    download_url_to_file "$url" "$output" "$app_title"
    return $?
}

detach_dmg() {
    local mount_point="$1"

    if [ -n "$mount_point" ] && [ -d "$mount_point" ]; then
        write_log "Отмонтирую DMG: $mount_point"
        hdiutil detach "$mount_point" -quiet
    fi
}

install_pkg_file() {
    local pkg_path="$1"
    local app_title="$2"

    write_log "Установка PKG: $pkg_path"

    sudo installer -pkg "$pkg_path" -target /
    local code=$?

    if [ "$code" -eq 0 ]; then
        write_log "Успешно установлено через PKG: $app_title"
    else
        write_log "Ошибка установки PKG: $app_title" "ERROR"
    fi

    return "$code"
}

copy_app_to_applications() {
    local app_path="$1"
    local app_title="$2"

    local target="/Applications/$(basename "$app_path")"

    write_log "Найдено приложение: $app_path"
    write_log "Цель установки: $target"

    if [ -d "$target" ]; then
        write_log "Удаляю старую версию: $target"
        sudo rm -rf "$target"
    fi

    write_log "Копирую приложение в /Applications"

    sudo ditto "$app_path" "$target"
    local code=$?

    if [ "$code" -eq 0 ]; then
        write_log "Успешно установлено приложение: $app_title"
    else
        write_log "Ошибка копирования приложения: $app_title" "ERROR"
    fi

    return "$code"
}

install_dmg() {
    local dmg_path="$1"
    local app_title="$2"

    local mount_output
    local mount_point
    local pkg_file
    local app_file

    if [ ! -f "$dmg_path" ]; then
        write_log "DMG файл не найден: $dmg_path" "ERROR"
        return 1
    fi

    write_log "Монтирую DMG: $dmg_path"

    mount_output="$(hdiutil attach "$dmg_path" -nobrowse 2>&1)"
    local attach_code=$?

    if [ "$attach_code" -ne 0 ]; then
        write_log "Ошибка монтирования DMG: $app_title" "ERROR"
        write_log "$mount_output" "ERROR"
        return 1
    fi

    mount_point="$(echo "$mount_output" | grep "/Volumes/" | sed -E 's/^.*(\/Volumes\/.*)$/\1/' | tail -n 1)"

    if [ -z "$mount_point" ] || [ ! -d "$mount_point" ]; then
        mount_point="$(hdiutil info | grep "/Volumes/" | tail -n 1 | sed -E 's/^.*(\/Volumes\/.*)$/\1/')"
    fi

    if [ -z "$mount_point" ] || [ ! -d "$mount_point" ]; then
        write_log "Не удалось определить точку монтирования для: $app_title" "ERROR"
        return 1
    fi

    write_log "DMG смонтирован: $mount_point"

    pkg_file="$(find "$mount_point" -maxdepth 5 -name "*.pkg" -type f | head -n 1)"
    app_file="$(find "$mount_point" -maxdepth 5 -name "*.app" -type d | head -n 1)"

    if [ -n "$pkg_file" ]; then
        install_pkg_file "$pkg_file" "$app_title"
        local code=$?
        detach_dmg "$mount_point"
        return "$code"
    fi

    if [ -n "$app_file" ]; then
        copy_app_to_applications "$app_file" "$app_title"
        local code=$?
        detach_dmg "$mount_point"
        return "$code"
    fi

    write_log "В DMG не найдено .pkg или .app: $app_title" "ERROR"
    detach_dmg "$mount_point"
    return 1
}

install_zip() {
    local zip_path="$1"
    local app_title="$2"

    local extract_dir="$DOWNLOAD_DIR/extracted-$app_title"
    local app_file
    local pkg_file

    if [ ! -f "$zip_path" ]; then
        write_log "ZIP файл не найден: $zip_path" "ERROR"
        return 1
    fi

    write_log "Распаковываю ZIP: $zip_path"

    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    unzip -q "$zip_path" -d "$extract_dir"
    local unzip_code=$?

    if [ "$unzip_code" -ne 0 ]; then
        write_log "Ошибка распаковки ZIP: $app_title" "ERROR"
        return 1
    fi

    pkg_file="$(find "$extract_dir" -maxdepth 5 -name "*.pkg" -type f | head -n 1)"
    app_file="$(find "$extract_dir" -maxdepth 5 -name "*.app" -type d | head -n 1)"

    if [ -n "$pkg_file" ]; then
        install_pkg_file "$pkg_file" "$app_title"
        return $?
    fi

    if [ -n "$app_file" ]; then
        copy_app_to_applications "$app_file" "$app_title"
        return $?
    fi

    write_log "В ZIP не найдено .pkg или .app: $app_title" "ERROR"
    return 1
}

install_file() {
    local file_path="$1"
    local app_title="$2"

    case "$file_path" in
        *.dmg|*.DMG)
            install_dmg "$file_path" "$app_title"
            ;;
        *.pkg|*.PKG)
            install_pkg_file "$file_path" "$app_title"
            ;;
        *.zip|*.ZIP)
            install_zip "$file_path" "$app_title"
            ;;
        *)
            write_log "Неподдерживаемый формат файла для $app_title: $file_path" "ERROR"
            return 1
            ;;
    esac
}

install_from_release() {
    local pattern="$1"
    local app_title="$2"

    local file_path

    file_path="$(download_asset "$pattern" "$app_title")"

    if [ -n "$file_path" ] && [ -f "$file_path" ]; then
        install_file "$file_path" "$app_title"
        return $?
    else
        write_log "Пропускаю установку, файл не скачан: $app_title" "WARN"
        return 1
    fi
}

download_openvpn_connect_from_brew_api() {
    local cask_json="$BASE_DIR/openvpn-connect-cask.json"
    local api_url="https://formulae.brew.sh/api/cask/openvpn-connect.json"
    local download_url
    local filename
    local output

    write_log "OpenVPN Connect не найден в GitHub Release"
    write_log "Пробую получить ссылку OpenVPN Connect через Homebrew Cask API"
    write_log "Homebrew устанавливаться не будет"

    curl -L \
        -H "User-Agent: OnboardingInstaller-macOS" \
        --connect-timeout 30 \
        --max-time 120 \
        -o "$cask_json" \
        "$api_url"

    if [ $? -ne 0 ] || [ ! -s "$cask_json" ]; then
        write_log "Не удалось получить Homebrew Cask JSON для OpenVPN Connect" "ERROR"
        return 1
    fi

    download_url="$(
        grep '"url"[[:space:]]*:' "$cask_json" \
            | head -n 1 \
            | sed -E 's/.*"url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
            | sed 's#\\/#/#g'
    )"

    if [ -z "$download_url" ]; then
        write_log "Не удалось извлечь URL OpenVPN Connect из Cask JSON" "ERROR"
        return 1
    fi

    filename="$(get_filename_from_url "$download_url")"

    if [[ "$filename" != *.dmg && "$filename" != *.pkg && "$filename" != *.zip ]]; then
        filename="OpenVPNConnect.dmg"
    fi

    output="$DOWNLOAD_DIR/$filename"

    download_url_to_file "$download_url" "$output" "OpenVPN Connect"
    return $?
}

install_openvpn_connect() {
    write_log "Начинаю установку OpenVPN Connect"

    local file_path

    file_path="$(download_asset "openvpn.*connect.*mac.*dmg|openvpn.*connect.*dmg|openvpn.*mac.*dmg|openvpn.*pkg" "OpenVPN Connect")"

    if [ -n "$file_path" ] && [ -f "$file_path" ]; then
        install_file "$file_path" "OpenVPN Connect"
        return $?
    fi

    file_path="$(download_openvpn_connect_from_brew_api)"

    if [ -n "$file_path" ] && [ -f "$file_path" ]; then
        install_file "$file_path" "OpenVPN Connect"
        return $?
    fi

    write_log "OpenVPN Connect не установлен" "ERROR"
    return 1
}

write_log "=== Старт установки onboarding ПО для macOS ==="

check_requirements

get_release_json
if [ $? -ne 0 ]; then
    write_log "Не удалось получить GitHub Release. Скрипт остановлен." "ERROR"
    exit 1
fi

show_assets

install_from_release "docker.*\.dmg" "Docker Desktop"
install_from_release "forticlient.*\.dmg|forti.*\.dmg" "FortiClient"
install_openvpn_connect
install_from_release "freelens.*macos.*\.dmg" "Freelens"
install_from_release "keepassxc.*x86_64.*\.dmg|keepassxc.*\.dmg" "KeePassXC"
install_from_release "postman.*macos.*\.zip|postman.*mac.*\.zip" "Postman"
install_from_release "slack.*macos.*\.dmg|slack.*mac.*\.dmg" "Slack"

write_log "Microsoft Office для macOS не установлен: в Release сейчас есть только OfficeSetup.exe для Windows" "WARN"
write_log "Yandex Telemost для macOS не установлен: в Release сейчас есть только TelemostSetup.exe для Windows" "WARN"
write_log "PDF Reader для macOS не установлен: в Release сейчас нет .dmg или .pkg" "WARN"

write_log "=== Установка завершена ==="
write_log "Лог: $LOG_FILE"

echo ""
echo "Готово."
echo "Лог установки:"
echo "$LOG_FILE"
