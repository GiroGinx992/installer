#!/bin/zsh

set +e

BASE_DIR="$HOME/Library/Application Support/OnboardingInstaller"
DOWNLOAD_DIR="$BASE_DIR/downloads"
EXTRACT_DIR="$BASE_DIR/extracted"
LOG_DIR="$HOME/Library/Logs/OnboardingInstaller"
LOG_FILE="$LOG_DIR/install-macos-official.log"

mkdir -p "$DOWNLOAD_DIR" "$EXTRACT_DIR" "$LOG_DIR"

write_log() {
    local message="$1"
    local level="${2:-INFO}"
    local now_time
    now_time="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[$now_time] [$level] $message"
    echo "$line" | tee -a "$LOG_FILE"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

detect_arch() {
    local raw_arch
    raw_arch="$(uname -m)"

    case "$raw_arch" in
        arm64)
            echo "arm64"
            ;;
        x86_64)
            echo "x64"
            ;;
        *)
            echo "$raw_arch"
            ;;
    esac
}

ARCH="$(detect_arch)"
MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null)"

write_log "============================================================"
write_log "Старт установки ПО для macOS"
write_log "Режим: только официальные источники"
write_log "macOS version: $MACOS_VERSION"
write_log "Architecture: $ARCH"
write_log "Log file: $LOG_FILE"
write_log "============================================================"

require_tools() {
    local missing=0

    for tool in curl hdiutil installer ditto unzip find awk sed grep basename du comm sort mktemp file pkgutil; do
        if ! command_exists "$tool"; then
            write_log "Не найдена системная команда: $tool" "ERROR"
            missing=1
        fi
    done

    if [[ "$missing" -eq 1 ]]; then
        write_log "Не хватает базовых системных команд macOS. Скрипт остановлен." "ERROR"
        exit 1
    fi
}

require_sudo() {
    write_log "Проверяю sudo-доступ..."

    if sudo -v; then
        write_log "sudo-доступ подтверждён." "SUCCESS"
    else
        write_log "Не удалось получить sudo-доступ." "ERROR"
        exit 1
    fi
}

keep_sudo_alive() {
    while true; do
        sudo -n true 2>/dev/null
        sleep 60
        kill -0 "$$" 2>/dev/null || exit
    done
}

app_exists() {
    local app_name="$1"

    if [[ -z "$app_name" ]]; then
        return 1
    fi

    if [[ -d "/Applications/$app_name.app" ]]; then
        return 0
    fi

    if [[ -d "$HOME/Applications/$app_name.app" ]]; then
        return 0
    fi

    return 1
}

any_app_exists() {
    local app

    for app in "$@"; do
        if app_exists "$app"; then
            return 0
        fi
    done

    return 1
}

pkg_receipt_exists() {
    local receipt_regex="$1"

    if [[ -z "$receipt_regex" ]]; then
        return 1
    fi

    pkgutil --pkgs 2>/dev/null | grep -Eiq "$receipt_regex"
    return $?
}

safe_filename() {
    echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

file_looks_like_format() {
    local file_path="$1"
    local expected_ext="$2"

    if [[ ! -s "$file_path" ]]; then
        return 1
    fi

    local info
    info="$(file "$file_path" 2>/dev/null)"

    case "$expected_ext" in
        dmg)
            echo "$info" | grep -Eiq 'Apple Disk Image|UDIF|bzip2 compressed data|zlib compressed data'
            return $?
            ;;
        pkg)
            echo "$info" | grep -Eiq 'xar archive|Mac OS X Installer|installer package'
            return $?
            ;;
        zip)
            echo "$info" | grep -Eiq 'Zip archive data'
            return $?
            ;;
        *)
            return 0
            ;;
    esac
}

download_file() {
    local display_name="$1"
    local url="$2"
    local output_file="$3"
    local expected_ext="$4"

    rm -f "$output_file"

    write_log "Скачиваю: $display_name"
    write_log "URL: $url"
    write_log "Файл: $output_file"

    local attempt=1
    local max_attempts=5
    local curl_code=1

    while [[ "$attempt" -le "$max_attempts" ]]; do
        write_log "Попытка $attempt/$max_attempts: $display_name"

        curl -L \
            --fail \
            --connect-timeout 30 \
            --retry 3 \
            --retry-delay 5 \
            --speed-time 120 \
            --speed-limit 1024 \
            --user-agent "Mozilla/5.0 macOS Official OnboardingInstaller" \
            -o "$output_file" \
            "$url"

        curl_code=$?

        if [[ "$curl_code" -eq 0 ]]; then
            break
        fi

        write_log "curl вернул код $curl_code для $display_name. Повтор через 10 секунд..." "WARN"
        sleep 10
        attempt=$((attempt + 1))
    done

    if [[ "$curl_code" -ne 0 ]]; then
        write_log "Ошибка скачивания: $display_name. Последний код curl: $curl_code" "ERROR"
        return 1
    fi

    if [[ ! -s "$output_file" ]]; then
        write_log "Файл скачался пустым: $output_file" "ERROR"
        return 1
    fi

    local size
    size="$(du -h "$output_file" | awk '{print $1}')"
    write_log "Файл скачан: $output_file ($size)" "SUCCESS"

    if [[ -n "$expected_ext" ]]; then
        if ! file_looks_like_format "$output_file" "$expected_ext"; then
            write_log "Файл не похож на .$expected_ext. Возможно, сайт отдал HTML вместо установщика." "ERROR"
            write_log "file output: $(file "$output_file" 2>/dev/null)" "ERROR"
            return 1
        fi
    fi

    return 0
}

copy_app_to_applications() {
    local app_path="$1"
    local app_basename
    app_basename="$(basename "$app_path")"

    if [[ ! -d "$app_path" ]]; then
        write_log "Не найден .app для копирования: $app_path" "ERROR"
        return 1
    fi

    write_log "Копирую $app_basename в /Applications"

    if [[ -d "/Applications/$app_basename" ]]; then
        write_log "Удаляю старую версию: /Applications/$app_basename"
        sudo rm -rf "/Applications/$app_basename"
    fi

    sudo ditto "$app_path" "/Applications/$app_basename"
    local copy_code=$?

    if [[ "$copy_code" -ne 0 ]]; then
        write_log "Ошибка копирования $app_basename. Код: $copy_code" "ERROR"
        return 1
    fi

    sudo xattr -dr com.apple.quarantine "/Applications/$app_basename" 2>/dev/null

    if [[ -d "/Applications/$app_basename" ]]; then
        write_log "Успешно установлено: /Applications/$app_basename" "SUCCESS"
        return 0
    fi

    write_log "После копирования приложение не найдено: /Applications/$app_basename" "ERROR"
    return 1
}

install_pkg_file() {
    local pkg_path="$1"
    local display_name="$2"

    if [[ ! -f "$pkg_path" ]]; then
        write_log "PKG не найден: $pkg_path" "ERROR"
        return 1
    fi

    if ! file_looks_like_format "$pkg_path" "pkg"; then
        write_log "Файл не является валидным PKG: $pkg_path" "ERROR"
        write_log "file output: $(file "$pkg_path" 2>/dev/null)" "ERROR"
        return 1
    fi

    write_log "Устанавливаю PKG: $pkg_path"

    sudo installer -pkg "$pkg_path" -target /
    local installer_code=$?

    if [[ "$installer_code" -eq 0 ]]; then
        write_log "PKG успешно установлен: $display_name" "SUCCESS"
        return 0
    fi

    write_log "Ошибка установки PKG: $display_name. Код installer: $installer_code" "ERROR"
    return 1
}

install_dmg_file() {
    local dmg_path="$1"
    local display_name="$2"

    if [[ ! -f "$dmg_path" ]]; then
        write_log "DMG не найден: $dmg_path" "ERROR"
        return 1
    fi

    if ! file_looks_like_format "$dmg_path" "dmg"; then
        write_log "Файл не является валидным DMG: $dmg_path" "ERROR"
        write_log "file output: $(file "$dmg_path" 2>/dev/null)" "ERROR"
        return 1
    fi

    write_log "Монтирую DMG: $dmg_path"

    local before_mounts
    local after_mounts
    local volume

    before_mounts="$(mktemp)"
    after_mounts="$(mktemp)"

    hdiutil info | awk '/\/Volumes\// {print substr($0, index($0, "/Volumes/"))}' > "$before_mounts"

    local attach_output
    attach_output="$(hdiutil attach "$dmg_path" -nobrowse 2>&1)"
    local attach_code=$?

    if [[ "$attach_code" -ne 0 ]]; then
        write_log "Не удалось смонтировать DMG: $display_name" "ERROR"
        write_log "$attach_output" "ERROR"
        rm -f "$before_mounts" "$after_mounts"
        return 1
    fi

    hdiutil info | awk '/\/Volumes\// {print substr($0, index($0, "/Volumes/"))}' > "$after_mounts"

    volume="$(comm -13 <(sort "$before_mounts") <(sort "$after_mounts") | tail -n 1)"

    rm -f "$before_mounts" "$after_mounts"

    if [[ -z "$volume" || ! -d "$volume" ]]; then
        volume="$(echo "$attach_output" | awk '/\/Volumes\// {print substr($0, index($0, "/Volumes/"))}' | tail -n 1)"
    fi

    if [[ -z "$volume" || ! -d "$volume" ]]; then
        write_log "Не удалось определить точку монтирования DMG: $display_name" "ERROR"
        return 1
    fi

    write_log "DMG смонтирован: $volume"

    local result=1

    local pkg_inside
    pkg_inside="$(find "$volume" -maxdepth 5 -type f -name "*.pkg" 2>/dev/null | head -n 1)"

    if [[ -n "$pkg_inside" ]]; then
        install_pkg_file "$pkg_inside" "$display_name"
        result=$?
    else
        local app_inside
        app_inside="$(find "$volume" -maxdepth 5 -type d -name "*.app" 2>/dev/null | head -n 1)"

        if [[ -n "$app_inside" ]]; then
            copy_app_to_applications "$app_inside"
            result=$?
        else
            write_log "Внутри DMG не найдено .app или .pkg: $display_name" "ERROR"
            result=1
        fi
    fi

    write_log "Отмонтирую DMG: $volume"
    hdiutil detach "$volume" -quiet >/dev/null 2>&1

    return $result
}

install_zip_file() {
    local zip_path="$1"
    local display_name="$2"

    if [[ ! -f "$zip_path" ]]; then
        write_log "ZIP не найден: $zip_path" "ERROR"
        return 1
    fi

    if ! file_looks_like_format "$zip_path" "zip"; then
        write_log "Файл не является валидным ZIP: $zip_path" "ERROR"
        write_log "file output: $(file "$zip_path" 2>/dev/null)" "ERROR"
        return 1
    fi

    local safe
    safe="$(safe_filename "$display_name")"
    local current_extract_dir="$EXTRACT_DIR/$safe"

    rm -rf "$current_extract_dir"
    mkdir -p "$current_extract_dir"

    write_log "Распаковываю ZIP: $zip_path"

    unzip -q "$zip_path" -d "$current_extract_dir"
    local unzip_code=$?

    if [[ "$unzip_code" -ne 0 ]]; then
        write_log "Ошибка распаковки ZIP: $display_name. Код unzip: $unzip_code" "ERROR"
        return 1
    fi

    local pkg_inside
    pkg_inside="$(find "$current_extract_dir" -maxdepth 7 -type f -name "*.pkg" 2>/dev/null | head -n 1)"

    if [[ -n "$pkg_inside" ]]; then
        install_pkg_file "$pkg_inside" "$display_name"
        return $?
    fi

    local app_inside
    app_inside="$(find "$current_extract_dir" -maxdepth 7 -type d -name "*.app" 2>/dev/null | head -n 1)"

    if [[ -n "$app_inside" ]]; then
        copy_app_to_applications "$app_inside"
        return $?
    fi

    write_log "Внутри ZIP не найдено .app или .pkg: $display_name" "ERROR"
    return 1
}

install_local_file() {
    local file_path="$1"
    local display_name="$2"

    case "$file_path" in
        *.dmg|*.DMG)
            install_dmg_file "$file_path" "$display_name"
            return $?
            ;;
        *.pkg|*.PKG)
            install_pkg_file "$file_path" "$display_name"
            return $?
            ;;
        *.zip|*.ZIP)
            install_zip_file "$file_path" "$display_name"
            return $?
            ;;
        *)
            write_log "Неподдерживаемый формат для macOS: $file_path" "ERROR"
            return 1
            ;;
    esac
}

install_from_url() {
    local display_name="$1"
    local app_check_csv="$2"
    local receipt_regex="$3"
    local url="$4"
    local extension="$5"

    IFS=',' read -rA app_checks <<< "$app_check_csv"

    if any_app_exists "${app_checks[@]}"; then
        write_log "Уже установлено: $display_name" "SUCCESS"
        return 0
    fi

    if pkg_receipt_exists "$receipt_regex"; then
        write_log "Уже установлено по pkg receipt: $display_name" "SUCCESS"
        return 0
    fi

    local safe
    safe="$(safe_filename "$display_name")"
    local local_file="$DOWNLOAD_DIR/${safe}.${extension}"

    write_log "Источник: официальный интернет-источник для $display_name"

    download_file "$display_name" "$url" "$local_file" "$extension"

    if [[ "$?" -ne 0 ]]; then
        write_log "Не удалось скачать или проверить установщик: $display_name" "ERROR"
        return 1
    fi

    install_local_file "$local_file" "$display_name"
    return $?
}

github_api_url() {
    local owner="$1"
    local repo="$2"

    echo "https://api.github.com/repos/$owner/$repo/releases/latest"
}

github_asset_url() {
    local owner="$1"
    local repo="$2"
    shift 2
    local patterns=("$@")

    local api
    api="$(github_api_url "$owner" "$repo")"

    local json_file="$DOWNLOAD_DIR/github_$(safe_filename "${owner}_${repo}_latest").json"

    write_log "Получаю официальный GitHub Release: $api"

    curl -L \
        --fail \
        --connect-timeout 30 \
        --retry 3 \
        --retry-delay 5 \
        --user-agent "Mozilla/5.0 macOS Official OnboardingInstaller" \
        -o "$json_file" \
        "$api" >/dev/null 2>&1

    if [[ "$?" -ne 0 || ! -s "$json_file" ]]; then
        write_log "Не удалось получить GitHub Release: $owner/$repo" "ERROR"
        return 1
    fi

    local urls
    urls="$(grep -E '"browser_download_url"[[:space:]]*:' "$json_file" | sed -E 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"

    local pattern
    for pattern in "${patterns[@]}"; do
        local matched
        matched="$(echo "$urls" | grep -Ei "$pattern" | grep -Eiv '\.(exe|msi|msix|appx|deb|rpm)$' | head -n 1)"

        if [[ -n "$matched" ]]; then
            echo "$matched"
            return 0
        fi
    done

    return 1
}

get_url_extension() {
    local url="$1"
    local clean
    clean="$(echo "$url" | sed 's/[?#].*$//')"

    case "$clean" in
        *.dmg|*.DMG)
            echo "dmg"
            ;;
        *.pkg|*.PKG)
            echo "pkg"
            ;;
        *.zip|*.ZIP)
            echo "zip"
            ;;
        *)
            echo ""
            ;;
    esac
}

install_from_official_github_release() {
    local display_name="$1"
    local app_check_csv="$2"
    local receipt_regex="$3"
    local owner="$4"
    local repo="$5"
    shift 5
    local patterns=("$@")

    IFS=',' read -rA app_checks <<< "$app_check_csv"

    if any_app_exists "${app_checks[@]}"; then
        write_log "Уже установлено: $display_name" "SUCCESS"
        return 0
    fi

    if pkg_receipt_exists "$receipt_regex"; then
        write_log "Уже установлено по pkg receipt: $display_name" "SUCCESS"
        return 0
    fi

    local url
    url="$(github_asset_url "$owner" "$repo" "${patterns[@]}")"

    if [[ -z "$url" ]]; then
        write_log "Не найден macOS asset в официальном GitHub Release для $display_name" "ERROR"
        return 1
    fi

    local raw_name
    raw_name="$(basename "$(echo "$url" | sed 's/[?#].*$//')" | sed 's/%20/ /g')"

    local ext
    ext="$(get_url_extension "$url")"

    if [[ -z "$ext" ]]; then
        write_log "Не удалось определить расширение файла для $display_name: $url" "ERROR"
        return 1
    fi

    local local_file="$DOWNLOAD_DIR/$raw_name"

    write_log "Источник: официальный GitHub Release для $display_name"
    write_log "Release URL: $url"

    download_file "$display_name" "$url" "$local_file" "$ext"

    if [[ "$?" -ne 0 ]]; then
        return 1
    fi

    install_local_file "$local_file" "$display_name"
    return $?
}



if [[ "$ARCH" == "arm64" ]]; then
    DOCKER_URL="https://desktop.docker.com/mac/main/arm64/Docker.dmg"
    POSTMAN_URL="https://dl.pstmn.io/download/latest/osx_arm64"
    SLACK_URL="https://slack.com/api/desktop.latestRelease?arch=arm64&redirect=1&variant=pkg"
else
    DOCKER_URL="https://desktop.docker.com/mac/main/amd64/Docker.dmg"
    POSTMAN_URL="https://dl.pstmn.io/download/latest/osx_64"
    SLACK_URL="https://slack.com/api/desktop.latestRelease?arch=x64&redirect=1&variant=pkg"
fi

TELEGRAM_URL="https://telegram.org/dl/macos"
OPENVPN_URL="https://openvpn.net/downloads/openvpn-connect-v3-macos.dmg"



require_tools
require_sudo

keep_sudo_alive &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1' EXIT



install_from_url \
    "Docker Desktop" \
    "Docker" \
    "com\.docker\." \
    "$DOCKER_URL" \
    "dmg"

install_from_url \
    "Slack" \
    "Slack" \
    "com\.tinyspeck\.slackmacgap|com\.slack\." \
    "$SLACK_URL" \
    "pkg"

install_from_url \
    "Telegram" \
    "Telegram" \
    "org\.telegram\.macos|ru\.keepcoder\.Telegram" \
    "$TELEGRAM_URL" \
    "dmg"

install_from_url \
    "Postman" \
    "Postman" \
    "" \
    "$POSTMAN_URL" \
    "zip"

install_from_url \
    "OpenVPN Connect" \
    "OpenVPN Connect" \
    "net\.openvpn\.connect|org\.openvpn\.client|net\.openvpn\.OpenVPNConnect" \
    "$OPENVPN_URL" \
    "dmg"



if [[ "$ARCH" == "arm64" ]]; then
    KEEPASS_PATTERNS=(
        "KeePassXC.*arm64.*\.dmg$"
        "KeePassXC.*aarch64.*\.dmg$"
        "KeePassXC.*macOS.*\.dmg$"
        "KeePassXC.*\.dmg$"
    )

    FREELENS_PATTERNS=(
        "Freelens.*arm64.*\.(dmg|pkg|zip)$"
        "Freelens.*aarch64.*\.(dmg|pkg|zip)$"
        "Freelens.*mac.*arm64.*\.(dmg|pkg|zip)$"
        "Freelens.*\.(dmg|pkg|zip)$"
    )
else
    KEEPASS_PATTERNS=(
        "KeePassXC.*x86_64.*\.dmg$"
        "KeePassXC.*x64.*\.dmg$"
        "KeePassXC.*macOS.*\.dmg$"
        "KeePassXC.*\.dmg$"
    )

    FREELENS_PATTERNS=(
        "Freelens.*amd64.*\.(dmg|pkg|zip)$"
        "Freelens.*x64.*\.(dmg|pkg|zip)$"
        "Freelens.*mac.*amd64.*\.(dmg|pkg|zip)$"
        "Freelens.*\.(dmg|pkg|zip)$"
    )
fi

install_from_official_github_release \
    "KeePassXC" \
    "KeePassXC" \
    "org\.keepassxc\.KeePassXC" \
    "keepassxreboot" \
    "keepassxc" \
    "${KEEPASS_PATTERNS[@]}"

install_from_official_github_release \
    "Freelens" \
    "Freelens" \
    "app\.freelens\.Freelens|com\.electron\.freelens" \
    "freelensapp" \
    "freelens" \
    "${FREELENS_PATTERNS[@]}"





FINAL_APPS=(
    "Docker"
    "Slack"
    "Telegram"
    "Postman"
    "OpenVPN Connect"
    "KeePassXC"
    "Freelens"
)

for app in "${FINAL_APPS[@]}"; do
    if app_exists "$app"; then
        write_log "OK: $app" "SUCCESS"
    else
        write_log "Не найдено в /Applications: $app" "WARN"
    fi
done

write_log "Эти программы лучше ставить вручную, потому что у них нестабильные прямые ссылки, онлайн-инсталляторы или silent-режим может не работать:" "WARN"
write_log "PDF Reader / Adobe Acrobat Reader:"
write_log "https://get.adobe.com/reader/"
write_log "FortiVPN / FortiClient VPN:"
write_log "https://www.fortinet.com/support/product-downloads"
write_log "Яндекс Телемост:"
write_log "https://telemost.yandex.ru/"
write_log "Microsoft Office для Mac намеренно НЕ устанавливается по твоему требованию." "WARN"

write_log "============================================================"
write_log "Установка завершена." "SUCCESS"
write_log "Лог: $LOG_FILE"
write_log "Команда для просмотра лога:"
write_log "tail -n 150 \"$LOG_FILE\""
write_log "============================================================"

exit 0
