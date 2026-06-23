#!/bin/zsh

set +e

GITHUB_OWNER="GiroGinx992"
GITHUB_REPO="installer"
GITHUB_TAG="onbording-v1"

SKIP_FORTIVPN=false
SKIP_YANDEX_TELEMOST=false
SKIP_ADOBE=false

for arg in "$@"; do
    case "$arg" in
        --skip-fortivpn) SKIP_FORTIVPN=true ;;
        --skip-yandex-telemost) SKIP_YANDEX_TELEMOST=true ;;
        --skip-adobe) SKIP_ADOBE=true ;;
        *) echo "[WARN] Неизвестный параметр: $arg" >&2 ;;
    esac
done

BASE_DIR="$HOME/Library/Application Support/OnboardingInstaller"
DOWNLOAD_DIR="$BASE_DIR/downloads"
EXTRACT_DIR="$BASE_DIR/extracted"
LOG_DIR="$HOME/Library/Logs/OnboardingInstaller"
LOG_FILE="$LOG_DIR/install-macos-github.log"
RELEASE_JSON="$DOWNLOAD_DIR/github-release.json"

mkdir -p "$DOWNLOAD_DIR" "$EXTRACT_DIR" "$LOG_DIR"

# Логи идут в stderr и файл. stdout оставлен чистым для возврата URL.
write_log() {
    local message="$1"
    local level="${2:-INFO}"
    local now_time
    now_time="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[$now_time] [$level] $message"
    echo "$line" | tee -a "$LOG_FILE" >&2
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

safe_filename() { echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'; }

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
    [[ -n "$app_name" && -d "/Applications/$app_name.app" ]] && return 0
    [[ -n "$app_name" && -d "$HOME/Applications/$app_name.app" ]] && return 0
    return 1
}

any_app_exists() {
    local app
    for app in "$@"; do
        app_exists "$app" && return 0
    done
    return 1
}

pkg_receipt_exists() {
    local receipt_regex="$1"
    [[ -z "$receipt_regex" ]] && return 1
    pkgutil --pkgs 2>/dev/null | grep -Eiq "$receipt_regex"
    return $?
}

file_looks_like_format() {
    local file_path="$1"
    local expected_ext="$2"
    [[ ! -s "$file_path" ]] && return 1

    local info
    info="$(file "$file_path" 2>/dev/null)"

    case "$expected_ext" in
        dmg) echo "$info" | grep -Eiq 'Apple Disk Image|UDIF|bzip2 compressed data|zlib compressed data' ;;
        pkg) echo "$info" | grep -Eiq 'xar archive|Mac OS X Installer|installer package' ;;
        zip) echo "$info" | grep -Eiq 'Zip archive data' ;;
        *) return 0 ;;
    esac
}

get_extension() {
    local value="$1"
    local clean
    clean="$(echo "$value" | sed 's/[?#].*$//')"
    case "$clean" in
        *.dmg|*.DMG) echo "dmg" ;;
        *.pkg|*.PKG) echo "pkg" ;;
        *.zip|*.ZIP) echo "zip" ;;
        *) echo "" ;;
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
        write_log "Попытка скачивания $attempt/$max_attempts: $display_name"
        curl -L \
            --fail \
            --connect-timeout 30 \
            --retry 3 \
            --retry-delay 5 \
            --speed-time 120 \
            --speed-limit 1024 \
            --user-agent "Mozilla/5.0 macOS GitHub Release Installer" \
            -o "$output_file" \
            "$url"

        curl_code=$?
        [[ "$curl_code" -eq 0 ]] && break

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

    write_log "Файл скачан: $output_file ($(du -h "$output_file" | awk '{print $1}'))" "SUCCESS"

    if [[ -n "$expected_ext" ]]; then
        if ! file_looks_like_format "$output_file" "$expected_ext"; then
            write_log "Файл не похож на .$expected_ext. Возможно, скачался HTML/ошибка вместо установщика." "ERROR"
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

    [[ ! -d "$app_path" ]] && { write_log "Не найден .app: $app_path" "ERROR"; return 1; }

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

    [[ ! -f "$pkg_path" ]] && { write_log "PKG не найден: $pkg_path" "ERROR"; return 1; }

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

    [[ ! -f "$dmg_path" ]] && { write_log "DMG не найден: $dmg_path" "ERROR"; return 1; }

    if ! file_looks_like_format "$dmg_path" "dmg"; then
        write_log "Файл не является валидным DMG: $dmg_path" "ERROR"
        write_log "file output: $(file "$dmg_path" 2>/dev/null)" "ERROR"
        return 1
    fi

    write_log "Монтирую DMG: $dmg_path"

    local before_mounts after_mounts volume attach_output attach_code
    before_mounts="$(mktemp)"
    after_mounts="$(mktemp)"

    hdiutil info | awk '/\/Volumes\// {print substr($0, index($0, "/Volumes/"))}' > "$before_mounts"

    attach_output="$(hdiutil attach "$dmg_path" -nobrowse 2>&1)"
    attach_code=$?

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
    local pkg_inside app_inside
    pkg_inside="$(find "$volume" -maxdepth 6 -type f -name "*.pkg" 2>/dev/null | head -n 1)"

    if [[ -n "$pkg_inside" ]]; then
        install_pkg_file "$pkg_inside" "$display_name"
        result=$?
    else
        app_inside="$(find "$volume" -maxdepth 6 -type d -name "*.app" 2>/dev/null | head -n 1)"
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

    [[ ! -f "$zip_path" ]] && { write_log "ZIP не найден: $zip_path" "ERROR"; return 1; }

    if ! file_looks_like_format "$zip_path" "zip"; then
        write_log "Файл не является валидным ZIP: $zip_path" "ERROR"
        write_log "file output: $(file "$zip_path" 2>/dev/null)" "ERROR"
        return 1
    fi

    local safe current_extract_dir pkg_inside app_inside
    safe="$(safe_filename "$display_name")"
    current_extract_dir="$EXTRACT_DIR/$safe"

    rm -rf "$current_extract_dir"
    mkdir -p "$current_extract_dir"

    write_log "Распаковываю ZIP: $zip_path"
    unzip -q "$zip_path" -d "$current_extract_dir"
    local unzip_code=$?

    if [[ "$unzip_code" -ne 0 ]]; then
        write_log "Ошибка распаковки ZIP: $display_name. Код unzip: $unzip_code" "ERROR"
        return 1
    fi

    pkg_inside="$(find "$current_extract_dir" -maxdepth 8 -type f -name "*.pkg" 2>/dev/null | head -n 1)"
    if [[ -n "$pkg_inside" ]]; then
        install_pkg_file "$pkg_inside" "$display_name"
        return $?
    fi

    app_inside="$(find "$current_extract_dir" -maxdepth 8 -type d -name "*.app" 2>/dev/null | head -n 1)"
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
        *.dmg|*.DMG) install_dmg_file "$file_path" "$display_name" ;;
        *.pkg|*.PKG) install_pkg_file "$file_path" "$display_name" ;;
        *.zip|*.ZIP) install_zip_file "$file_path" "$display_name" ;;
        *) write_log "Неподдерживаемый формат для macOS: $file_path" "ERROR"; return 1 ;;
    esac
}

github_api_url() {
    echo "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/releases/tags/$GITHUB_TAG"
}

get_release_json() {
    local api_url
    api_url="$(github_api_url)"

    write_log "Получаю список файлов GitHub Release:"
    write_log "$api_url"

    curl -L \
        --fail \
        --connect-timeout 30 \
        --retry 3 \
        --retry-delay 5 \
        --user-agent "Mozilla/5.0 macOS GitHub Release Installer" \
        -o "$RELEASE_JSON" \
        "$api_url"

    if [[ "$?" -ne 0 || ! -s "$RELEASE_JSON" ]]; then
        write_log "Не удалось получить GitHub Release." "ERROR"
        return 1
    fi

    write_log "GitHub Release получен: $RELEASE_JSON" "SUCCESS"
    return 0
}

list_release_assets() {
    [[ ! -s "$RELEASE_JSON" ]] && return 1

    grep -E '"browser_download_url"[[:space:]]*:' "$RELEASE_JSON" \
        | sed -E 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
        | grep -Eiv '\.(exe|msi|msix|appx|deb|rpm)$'
}

find_asset_url() {
    local patterns=("$@")
    local urls pattern matched
    urls="$(list_release_assets)"

    for pattern in "${patterns[@]}"; do
        matched="$(echo "$urls" | grep -Ei "$pattern" | head -n 1)"
        if [[ -n "$matched" ]]; then
            echo "$matched"
            return 0
        fi
    done

    return 1
}

install_from_github_asset() {
    local display_name="$1"
    local app_check_csv="$2"
    local receipt_regex="$3"
    shift 3
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

    local url raw_name ext local_file
    url="$(find_asset_url "${patterns[@]}")"

    if [[ -z "$url" ]]; then
        write_log "Не найден macOS-файл в GitHub Release для: $display_name" "WARN"
        return 1
    fi

    raw_name="$(basename "$(echo "$url" | sed 's/[?#].*$//')" | sed 's/%20/ /g')"
    ext="$(get_extension "$raw_name")"

    if [[ -z "$ext" ]]; then
        write_log "Не удалось определить формат файла для $display_name: $raw_name" "ERROR"
        return 1
    fi

    local_file="$DOWNLOAD_DIR/$raw_name"

    write_log "Найден файл для $display_name: $raw_name"
    write_log "Формат: .$ext"

    download_file "$display_name" "$url" "$local_file" "$ext"
    [[ "$?" -ne 0 ]] && return 1

    install_local_file "$local_file" "$display_name"
    return $?
}

# =====================================================================
# Запуск
# =====================================================================

require_tools
require_sudo

keep_sudo_alive &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1' EXIT

write_log "============================================================"
write_log "Система"
write_log "============================================================"
write_log "macOS: $(sw_vers -productVersion 2>/dev/null)"
write_log "Architecture: $(uname -m)"

get_release_json
if [[ "$?" -ne 0 ]]; then
    write_log "Скрипт остановлен: нет доступа к GitHub Release или tag неверный." "ERROR"
    exit 1
fi

write_log "============================================================"
write_log "Доступные macOS assets в Release"
write_log "============================================================"
list_release_assets | while read -r asset_url; do
    write_log "$(basename "$asset_url" | sed 's/%20/ /g')"
done

write_log "============================================================"
write_log "Установка программ из GitHub Release"
write_log "============================================================"

install_from_github_asset \
    "Docker Desktop" \
    "Docker" \
    "com\.docker\." \
    "Docker.*\.dmg$"

install_from_github_asset \
    "Slack" \
    "Slack" \
    "com\.tinyspeck\.slackmacgap|com\.slack\." \
    "Slack.*\.(dmg|pkg|zip)$"

install_from_github_asset \
    "Telegram" \
    "Telegram" \
    "org\.telegram\.macos|ru\.keepcoder\.Telegram" \
    "Telegram.*\.(dmg|zip)$"

install_from_github_asset \
    "Postman" \
    "Postman" \
    "" \
    "Postman.*macOS.*arm64.*\.(zip|dmg)$" \
    "Postman.*macOS.*x64.*\.(zip|dmg)$" \
    "Postman.*macOS.*\.(zip|dmg)$" \
    "Postman.*\.(zip|dmg)$"

install_from_github_asset \
    "OpenVPN Connect" \
    "OpenVPN Connect" \
    "net\.openvpn\.connect|org\.openvpn\.client|net\.openvpn\.OpenVPNConnect" \
    "OpenVPN.*\.(dmg|pkg|zip)$" \
    "openvpn.*\.(dmg|pkg|zip)$"

install_from_github_asset \
    "KeePassXC" \
    "KeePassXC" \
    "org\.keepassxc\.KeePassXC" \
    "KeePassXC.*arm64.*\.dmg$" \
    "KeePassXC.*x86_64.*\.dmg$" \
    "KeePassXC.*x64.*\.dmg$" \
    "KeePassXC.*\.dmg$"

install_from_github_asset \
    "Freelens" \
    "Freelens" \
    "app\.freelens\.Freelens|com\.electron\.freelens" \
    "Freelens.*arm64.*\.(dmg|pkg|zip)$" \
    "Freelens.*x64.*\.(dmg|pkg|zip)$" \
    "Freelens.*\.(dmg|pkg|zip)$"

if [[ "$SKIP_ADOBE" == false ]]; then
    install_from_github_asset \
        "Adobe Acrobat Reader / PDF Reader" \
        "Adobe Acrobat Reader,Adobe Acrobat Reader DC,Acrobat Reader" \
        "com\.adobe\.Reader|com\.adobe\.Acrobat\.Reader" \
        "Adobe.*Reader.*\.(dmg|pkg|zip)$" \
        "Acrobat.*Reader.*\.(dmg|pkg|zip)$" \
        "Acro.*Reader.*\.(dmg|pkg|zip)$" \
        "PDF.*Reader.*\.(dmg|pkg|zip)$"
else
    write_log "Adobe Reader пропущен параметром --skip-adobe" "WARN"
fi

if [[ "$SKIP_FORTIVPN" == false ]]; then
    install_from_github_asset \
        "FortiVPN / FortiClient VPN" \
        "FortiClient,FortiClient VPN" \
        "com\.fortinet\." \
        "Forti.*Client.*\.(dmg|pkg|zip)$" \
        "Forti.*VPN.*\.(dmg|pkg|zip)$" \
        "FortiClient.*\.(dmg|pkg|zip)$"
else
    write_log "FortiVPN пропущен параметром --skip-fortivpn" "WARN"
fi

if [[ "$SKIP_YANDEX_TELEMOST" == false ]]; then
    install_from_github_asset \
        "Яндекс Телемост" \
        "Яндекс Телемост,Yandex Telemost,Telemost" \
        "ru\.yandex\..*telemost|com\.yandex\..*telemost" \
        ".*Telemost.*\.(dmg|pkg|zip)$" \
        ".*Телемост.*\.(dmg|pkg|zip)$" \
        ".*Yandex.*Meet.*\.(dmg|pkg|zip)$" \
        ".*Yandex.*Telemost.*\.(dmg|pkg|zip)$"
else
    write_log "Яндекс Телемост пропущен параметром --skip-yandex-telemost" "WARN"
fi

write_log "============================================================"
write_log "Финальная проверка /Applications"
write_log "============================================================"

FINAL_APPS=(
    "Adobe Acrobat Reader"
    "Adobe Acrobat Reader DC"
    "Acrobat Reader"
    "Docker"
    "FortiClient"
    "FortiClient VPN"
    "Freelens"
    "KeePassXC"
    "OpenVPN Connect"
    "Postman"
    "Slack"
    "Telegram"
    "Яндекс Телемост"
    "Yandex Telemost"
    "Telemost"
)

for app in "${FINAL_APPS[@]}"; do
    if app_exists "$app"; then
        write_log "OK: $app" "SUCCESS"
    else
        write_log "Не найдено в /Applications: $app" "WARN"
    fi
done

write_log "============================================================"
write_log "Установка завершена." "SUCCESS"
write_log "Лог: $LOG_FILE"
write_log "Команда для просмотра лога:"
write_log "tail -n 150 \"$LOG_FILE\""
write_log "============================================================"

exit 0
