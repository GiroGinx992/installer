#!/bin/zsh


set +e

GITHUB_OWNER="GiroGinx992"
GITHUB_REPO="installer"
GITHUB_TAG="onbording-v1"

SKIP_FORTIVPN=false
SKIP_YANDEX_TELEMOST=false
SKIP_ADOBE=false
FALLBACK_GITHUB=false

for arg in "$@"; do
    case "$arg" in
        --skip-fortivpn)
            SKIP_FORTIVPN=true
            ;;
        --skip-yandex-telemost)
            SKIP_YANDEX_TELEMOST=true
            ;;
        --skip-adobe)
            SKIP_ADOBE=true
            ;;
        --fallback-github)
            FALLBACK_GITHUB=true
            ;;
        *)
            echo "[WARN] Неизвестный параметр: $arg"
            ;;
    esac
done

BASE_DIR="$HOME/Library/Application Support/OnboardingInstaller"
DOWNLOAD_DIR="$BASE_DIR/downloads"
EXTRACT_DIR="$BASE_DIR/extracted"
LOG_DIR="$HOME/Library/Logs/OnboardingInstaller"
LOG_FILE="$LOG_DIR/install-macos.log"

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
write_log "Старт установки onboarding ПО для macOS"
write_log "macOS version: $MACOS_VERSION"
write_log "Architecture: $ARCH"
write_log "Log file: $LOG_FILE"
write_log "GitHub fallback: $FALLBACK_GITHUB"
write_log "============================================================"

require_tools() {
    local missing=0

    for tool in curl hdiutil installer ditto unzip find awk sed grep basename du comm sort mktemp; do
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

require_tools
require_sudo

keep_sudo_alive &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1' EXIT

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

download_file() {
    local display_name="$1"
    local url="$2"
    local output_file="$3"

    rm -f "$output_file"

    write_log "Скачиваю: $display_name"
    write_log "URL: $url"
    write_log "Файл: $output_file"

    curl -L \
        --fail \
        --connect-timeout 30 \
        --retry 3 \
        --retry-delay 5 \
        --user-agent "Mozilla/5.0 macOS OnboardingInstaller" \
        -o "$output_file" \
        "$url"

    local curl_code=$?

    if [[ "$curl_code" -ne 0 ]]; then
        write_log "Ошибка скачивания: $display_name. Код curl: $curl_code" "ERROR"
        rm -f "$output_file"
        return 1
    fi

    if [[ ! -s "$output_file" ]]; then
        write_log "Файл скачался пустым: $output_file" "ERROR"
        rm -f "$output_file"
        return 1
    fi

    local size
    size="$(du -h "$output_file" | awk '{print $1}')"
    write_log "Файл скачан: $output_file ($size)" "SUCCESS"

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
    pkg_inside="$(find "$volume" -maxdepth 4 -type f -name "*.pkg" 2>/dev/null | head -n 1)"

    if [[ -n "$pkg_inside" ]]; then
        install_pkg_file "$pkg_inside" "$display_name"
        result=$?
    else
        local app_inside
        app_inside="$(find "$volume" -maxdepth 4 -type d -name "*.app" 2>/dev/null | head -n 1)"

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
    pkg_inside="$(find "$current_extract_dir" -maxdepth 6 -type f -name "*.pkg" 2>/dev/null | head -n 1)"

    if [[ -n "$pkg_inside" ]]; then
        install_pkg_file "$pkg_inside" "$display_name"
        return $?
    fi

    local app_inside
    app_inside="$(find "$current_extract_dir" -maxdepth 6 -type d -name "*.app" 2>/dev/null | head -n 1)"

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

github_api_url() {
    local owner="$1"
    local repo="$2"
    local tag="$3"

    if [[ "$tag" == "latest" ]]; then
        echo "https://api.github.com/repos/$owner/$repo/releases/latest"
    else
        echo "https://api.github.com/repos/$owner/$repo/releases/tags/$tag"
    fi
}

github_asset_url() {
    local owner="$1"
    local repo="$2"
    local tag="$3"
    shift 3
    local patterns=("$@")

    local api
    api="$(github_api_url "$owner" "$repo" "$tag")"

    local json_file="$DOWNLOAD_DIR/github_$(safe_filename "${owner}_${repo}_${tag}").json"

    write_log "Получаю GitHub Release: $api"

    curl -L \
        --fail \
        --connect-timeout 30 \
        --retry 3 \
        --retry-delay 5 \
        --user-agent "Mozilla/5.0 macOS OnboardingInstaller" \
        -o "$json_file" \
        "$api"

    if [[ "$?" -ne 0 || ! -s "$json_file" ]]; then
        write_log "Не удалось получить GitHub Release: $owner/$repo:$tag" "ERROR"
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

install_from_github_release() {
    local display_name="$1"
    local app_check_csv="$2"
    local receipt_regex="$3"
    local owner="$4"
    local repo="$5"
    local tag="$6"
    shift 6
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
    url="$(github_asset_url "$owner" "$repo" "$tag" "${patterns[@]}")"

    if [[ -z "$url" ]]; then
        write_log "Не найден подходящий macOS файл для $display_name в GitHub Release $owner/$repo:$tag" "WARN"
        return 1
    fi

    local raw_name
    raw_name="$(basename "$url" | sed 's/%20/ /g')"
    local local_file="$DOWNLOAD_DIR/$raw_name"

    write_log "Источник: GitHub Release для $display_name"
    download_file "$display_name" "$url" "$local_file"

    if [[ "$?" -ne 0 ]]; then
        return 1
    fi

    install_local_file "$local_file" "$display_name"
    return $?
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

    download_file "$display_name" "$url" "$local_file"

    if [[ "$?" -ne 0 ]]; then
        return 1
    fi

    install_local_file "$local_file" "$display_name"
    return $?
}

install_from_url_with_github_fallback() {
    local display_name="$1"
    local app_check_csv="$2"
    local receipt_regex="$3"
    local official_url="$4"
    local extension="$5"
    shift 5
    local fallback_patterns=("$@")

    install_from_url "$display_name" "$app_check_csv" "$receipt_regex" "$official_url" "$extension"
    local result=$?

    if [[ "$result" -eq 0 ]]; then
        return 0
    fi

    if [[ "$FALLBACK_GITHUB" == true ]]; then
        write_log "Официальная установка не сработала для $display_name. Пробую твой GitHub Release..." "WARN"
        install_from_github_release "$display_name" "$app_check_csv" "$receipt_regex" "$GITHUB_OWNER" "$GITHUB_REPO" "$GITHUB_TAG" "${fallback_patterns[@]}"
        return $?
    fi

    write_log "Установка не удалась: $display_name. Fallback GitHub выключен. Можно включить --fallback-github" "WARN"
    return 1
}

# =====================================================================
# Официальные URL
# =====================================================================

if [[ "$ARCH" == "arm64" ]]; then
    DOCKER_URL="https://desktop.docker.com/mac/main/arm64/Docker.dmg"
    POSTMAN_URL="https://dl.pstmn.io/download/latest/osx_arm64"
else
    DOCKER_URL="https://desktop.docker.com/mac/main/amd64/Docker.dmg"
    POSTMAN_URL="https://dl.pstmn.io/download/latest/osx_64"
fi

SLACK_URL="https://slack.com/ssb/download-osx-universal"
TELEGRAM_URL="https://macos.telegram.org/dl"
OFFICE_URL="https://go.microsoft.com/fwlink/?linkid=2009112"
OPENVPN_URL="https://openvpn.net/downloads/openvpn-connect-v3-macos.dmg"

write_log "============================================================"
write_log "Установка из официальных источников"
write_log "============================================================"

install_from_url_with_github_fallback \
    "Docker Desktop" \
    "Docker" \
    "com\.docker\." \
    "$DOCKER_URL" \
    "dmg" \
    "Docker.*\.dmg$"

install_from_url_with_github_fallback \
    "Slack" \
    "Slack" \
    "com\.tinyspeck\.slackmacgap|com\.slack\." \
    "$SLACK_URL" \
    "pkg" \
    "Slack.*\.(pkg|dmg|zip)$"

install_from_url_with_github_fallback \
    "Telegram" \
    "Telegram" \
    "org\.telegram\.macos|ru\.keepcoder\.Telegram" \
    "$TELEGRAM_URL" \
    "dmg" \
    "Telegram.*\.(dmg|zip)$"

install_from_url_with_github_fallback \
    "Postman" \
    "Postman" \
    "" \
    "$POSTMAN_URL" \
    "zip" \
    "Postman.*macOS.*\.(zip|dmg)$|Postman.*\.(zip|dmg)$"

install_from_url_with_github_fallback \
    "Microsoft Office 365" \
    "Microsoft Word,Microsoft Excel,Microsoft PowerPoint,Microsoft Outlook" \
    "com\.microsoft\.office|com\.microsoft\.Word|com\.microsoft\.Excel" \
    "$OFFICE_URL" \
    "pkg" \
    "Microsoft.*Office.*\.(pkg|dmg)$|Office.*\.(pkg|dmg)$"

install_from_url_with_github_fallback \
    "OpenVPN Connect" \
    "OpenVPN Connect" \
    "net\.openvpn\.connect|org\.openvpn\.client|net\.openvpn\.OpenVPNConnect" \
    "$OPENVPN_URL" \
    "dmg" \
    "OpenVPN.*\.(dmg|pkg)$|openvpn.*\.(dmg|pkg)$"

write_log "============================================================"
write_log "Установка из официальных GitHub Releases проектов"
write_log "============================================================"

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

install_from_github_release \
    "KeePassXC" \
    "KeePassXC" \
    "org\.keepassxc\.KeePassXC" \
    "keepassxreboot" \
    "keepassxc" \
    "latest" \
    "${KEEPASS_PATTERNS[@]}"

install_from_github_release \
    "Freelens" \
    "Freelens" \
    "app\.freelens\.Freelens|com\.electron\.freelens" \
    "freelensapp" \
    "freelens" \
    "latest" \
    "${FREELENS_PATTERNS[@]}"

write_log "============================================================"
write_log "Установка из твоего GitHub Release"
write_log "============================================================"

if [[ "$SKIP_ADOBE" == false ]]; then
    install_from_github_release \
        "Adobe Acrobat Reader / PDF Reader" \
        "Adobe Acrobat Reader,Adobe Acrobat Reader DC,Acrobat Reader" \
        "com\.adobe\.Reader|com\.adobe\.Acrobat\.Reader" \
        "$GITHUB_OWNER" \
        "$GITHUB_REPO" \
        "$GITHUB_TAG" \
        "Adobe.*Reader.*\.(dmg|pkg|zip)$" \
        "Acrobat.*Reader.*\.(dmg|pkg|zip)$" \
        "Acro.*Reader.*\.(dmg|pkg|zip)$" \
        "PDF.*Reader.*\.(dmg|pkg|zip)$"
else
    write_log "Adobe Reader пропущен параметром --skip-adobe" "WARN"
fi

if [[ "$SKIP_FORTIVPN" == false ]]; then
    install_from_github_release \
        "FortiVPN / FortiClient VPN" \
        "FortiClient,FortiClient VPN" \
        "com\.fortinet\." \
        "$GITHUB_OWNER" \
        "$GITHUB_REPO" \
        "$GITHUB_TAG" \
        "Forti.*Client.*\.(dmg|pkg|zip)$" \
        "Forti.*VPN.*\.(dmg|pkg|zip)$" \
        "FortiClient.*\.(dmg|pkg|zip)$"
else
    write_log "FortiVPN пропущен параметром --skip-fortivpn" "WARN"
fi

if [[ "$SKIP_YANDEX_TELEMOST" == false ]]; then
    install_from_github_release \
        "Яндекс Телемост" \
        "Яндекс Телемост,Yandex Telemost,Telemost" \
        "ru\.yandex\..*telemost|com\.yandex\..*telemost" \
        "$GITHUB_OWNER" \
        "$GITHUB_REPO" \
        "$GITHUB_TAG" \
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
    "Microsoft Word"
    "Microsoft Excel"
    "Microsoft PowerPoint"
    "Microsoft Outlook"
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
write_log "Если что-то не установилось, пришли последние 150 строк лога:" "WARN"
write_log "tail -n 150 \"$LOG_FILE\""
write_log "============================================================"

exit 0
