#!/bin/zsh


set +e

GITHUB_OWNER="${GITHUB_OWNER:-GiroGinx992}"
GITHUB_REPO="${GITHUB_REPO:-installer}"
GITHUB_TAG="${GITHUB_TAG:-onbording-v1}"

SKIP_FORTIVPN=false
SKIP_YANDEX_TELEMOST=false

for arg in "$@"; do
    case "$arg" in
        --skip-fortivpn)
            SKIP_FORTIVPN=true
            ;;
        --skip-yandex-telemost)
            SKIP_YANDEX_TELEMOST=true
            ;;
        --owner=*)
            GITHUB_OWNER="${arg#*=}"
            ;;
        --repo=*)
            GITHUB_REPO="${arg#*=}"
            ;;
        --tag=*)
            GITHUB_TAG="${arg#*=}"
            ;;
        *)
            echo "Неизвестный параметр: $arg"
            echo "Доступно: --skip-fortivpn --skip-yandex-telemost --owner=OWNER --repo=REPO --tag=TAG"
            exit 1
            ;;
    esac
done

BASE_DIR="$HOME/Library/Application Support/OnboardingInstaller"
DOWNLOAD_DIR="$BASE_DIR/downloads"
WORK_DIR="$BASE_DIR/work"
LOG_DIR="$HOME/Library/Logs/OnboardingInstaller"
LOG_FILE="$LOG_DIR/install-macos.log"

mkdir -p "$DOWNLOAD_DIR" "$WORK_DIR" "$LOG_DIR"

touch "$LOG_FILE" 2>/dev/null

write_log() {
    local message="$1"
    local level="${2:-INFO}"
    local time_now
    time_now="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[$time_now] [$level] $message"
    echo "$line" | tee -a "$LOG_FILE"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

need_command() {
    local cmd="$1"
    if ! command_exists "$cmd"; then
        write_log "Не найдена системная команда: $cmd" "ERROR"
        return 1
    fi
    return 0
}

check_required_commands() {
    local failed=false
    for cmd in curl hdiutil installer ditto unzip find grep sed awk stat; do
        if ! need_command "$cmd"; then
            failed=true
        fi
    done

    if [ "$failed" = true ]; then
        write_log "Не хватает системных команд. Установка остановлена." "ERROR"
        exit 1
    fi
}

check_macos() {
    local version arch
    version="$(sw_vers -productVersion 2>/dev/null)"
    arch="$(uname -m)"
    write_log "macOS version: $version"
    write_log "CPU architecture: $arch"
}

check_sudo() {
    write_log "Проверяю sudo-права. macOS может запросить пароль пользователя."
    sudo -v
    if [ $? -ne 0 ]; then
        write_log "Не удалось получить sudo-права. Запусти скрипт под пользователем-администратором." "ERROR"
        exit 1
    fi

    
    while true; do
        sudo -n true 2>/dev/null
        sleep 60
        kill -0 "$$" 2>/dev/null || exit
    done &
}

normalize_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

app_exists() {
    local app_name="$1"

    if [ -d "/Applications/$app_name.app" ]; then
        return 0
    fi

    if [ -d "$HOME/Applications/$app_name.app" ]; then
        return 0
    fi

    return 1
}

pkg_id_exists() {
    local pkg_id="$1"

    if [ -z "$pkg_id" ]; then
        return 1
    fi

    pkgutil --pkgs 2>/dev/null | grep -Eiq "^${pkg_id}$"
    return $?
}

is_installed() {
    local display_name="$1"
    local app_name="$2"
    local pkg_id="$3"

    if [ -n "$app_name" ] && app_exists "$app_name"; then
        write_log "Уже установлено: $display_name (/Applications/$app_name.app)" "SUCCESS"
        return 0
    fi

    if [ -n "$pkg_id" ] && pkg_id_exists "$pkg_id"; then
        write_log "Уже установлено: $display_name (pkg: $pkg_id)" "SUCCESS"
        return 0
    fi

    return 1
}

get_release_asset_urls() {
    local api_url="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tags/${GITHUB_TAG}"
    write_log "Получаю список файлов GitHub Release: $api_url"

    curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: onboarding-macos-installer" \
        "$api_url" |
        grep -Eo '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' |
        sed -E 's/^"browser_download_url"[[:space:]]*:[[:space:]]*"//; s/"$//'
}

select_asset_url() {
    local display_name="$1"
    local patterns="$2"
    local allowed_ext_regex="$3"
    local urls="$4"
    local arch
    arch="$(uname -m)"

    local filtered
    filtered="$(echo "$urls" | grep -Ei "$allowed_ext_regex" | grep -Eiv '\.(exe|msi|msix|msixbundle)$')"

    local pattern
    local matches=""

    IFS='|' read -rA pattern_array <<< "$patterns"

    for pattern in "${pattern_array[@]}"; do
        matches="$(echo "$filtered" | grep -Ei "$pattern")"
        if [ -n "$matches" ]; then
            break
        fi
    done

    if [ -z "$matches" ]; then
        write_log "Не найден macOS-файл в GitHub Release для: $display_name" "WARN"
        return 1
    fi

    local preferred=""

    if [ "$arch" = "arm64" ]; then
        preferred="$(echo "$matches" | grep -Ei 'arm64|aarch64|apple.?silicon|silicon' | head -n 1)"
        if [ -z "$preferred" ]; then
            preferred="$(echo "$matches" | grep -Eiv 'x64|x86|intel|amd64' | head -n 1)"
        fi
    else
        preferred="$(echo "$matches" | grep -Ei 'x64|x86_64|intel|amd64' | head -n 1)"
        if [ -z "$preferred" ]; then
            preferred="$(echo "$matches" | grep -Eiv 'arm64|aarch64|apple.?silicon|silicon' | head -n 1)"
        fi
    fi

    if [ -z "$preferred" ]; then
        preferred="$(echo "$matches" | head -n 1)"
    fi

    echo "$preferred"
    return 0
}

download_file() {
    local url="$1"
    local local_file="$2"
    local display_name="$3"

    if [ -f "$local_file" ]; then
        local size
        size="$(stat -f%z "$local_file" 2>/dev/null)"
        if [ -n "$size" ] && [ "$size" -gt 1024 ]; then
            write_log "Файл уже скачан: $local_file"
            return 0
        fi
    fi

    write_log "Скачиваю $display_name"
    write_log "URL: $url"
    write_log "Куда: $local_file"

    curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$local_file" "$url"
    local code=$?

    if [ $code -ne 0 ]; then
        write_log "Ошибка скачивания $display_name. Код curl: $code" "ERROR"
        return 1
    fi

    if [ ! -f "$local_file" ]; then
        write_log "Файл не появился после скачивания: $local_file" "ERROR"
        return 1
    fi

    write_log "Файл скачан: $local_file" "SUCCESS"
    return 0
}

install_pkg() {
    local pkg_file="$1"
    local display_name="$2"

    write_log "Устанавливаю PKG: $display_name"
    sudo installer -pkg "$pkg_file" -target /
    local code=$?

    if [ $code -eq 0 ]; then
        write_log "Успешно установлено через PKG: $display_name" "SUCCESS"
        return 0
    fi

    write_log "Ошибка установки PKG: $display_name. Код: $code" "ERROR"
    return 1
}

copy_app_to_applications() {
    local app_path="$1"
    local display_name="$2"
    local app_base
    app_base="$(basename "$app_path")"

    write_log "Копирую приложение в /Applications: $app_base"

    if [ -d "/Applications/$app_base" ]; then
        write_log "Удаляю старую версию: /Applications/$app_base" "WARN"
        sudo rm -rf "/Applications/$app_base"
    fi

    sudo ditto "$app_path" "/Applications/$app_base"
    local code=$?

    if [ $code -eq 0 ]; then
        sudo xattr -dr com.apple.quarantine "/Applications/$app_base" 2>/dev/null
        write_log "Успешно установлено приложение: $display_name" "SUCCESS"
        return 0
    fi

    write_log "Ошибка копирования приложения: $display_name. Код: $code" "ERROR"
    return 1
}

install_dmg() {
    local dmg_file="$1"
    local display_name="$2"
    local mount_point=""

    write_log "Монтирую DMG: $display_name"

    mount_point="$(hdiutil attach "$dmg_file" -nobrowse -quiet 2>/dev/null | awk '/\/Volumes\// {print substr($0, index($0, "/Volumes/")); exit}')"

    if [ -z "$mount_point" ] || [ ! -d "$mount_point" ]; then
        write_log "Не удалось смонтировать DMG: $dmg_file" "ERROR"
        return 1
    fi

    write_log "DMG смонтирован: $mount_point"

    local pkg_inside app_inside
    pkg_inside="$(find "$mount_point" -maxdepth 3 -type f -name '*.pkg' | head -n 1)"
    app_inside="$(find "$mount_point" -maxdepth 3 -type d -name '*.app' | head -n 1)"

    local result=1

    if [ -n "$pkg_inside" ]; then
        install_pkg "$pkg_inside" "$display_name"
        result=$?
    elif [ -n "$app_inside" ]; then
        copy_app_to_applications "$app_inside" "$display_name"
        result=$?
    else
        write_log "В DMG не найден .app или .pkg: $display_name" "ERROR"
        result=1
    fi

    write_log "Отмонтирую DMG: $mount_point"
    hdiutil detach "$mount_point" -quiet 2>/dev/null
    if [ $? -ne 0 ]; then
        hdiutil detach "$mount_point" -force -quiet 2>/dev/null
    fi

    return $result
}

install_zip() {
    local zip_file="$1"
    local display_name="$2"
    local extract_dir="$WORK_DIR/$(basename "$zip_file" .zip)-extract"

    write_log "Распаковываю ZIP: $zip_file"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    unzip -oq "$zip_file" -d "$extract_dir"
    local code=$?

    if [ $code -ne 0 ]; then
        write_log "Ошибка распаковки ZIP: $display_name. Код: $code" "ERROR"
        return 1
    fi

    local pkg_inside app_inside
    pkg_inside="$(find "$extract_dir" -maxdepth 5 -type f -name '*.pkg' | head -n 1)"
    app_inside="$(find "$extract_dir" -maxdepth 5 -type d -name '*.app' | head -n 1)"

    if [ -n "$pkg_inside" ]; then
        install_pkg "$pkg_inside" "$display_name"
        return $?
    fi

    if [ -n "$app_inside" ]; then
        copy_app_to_applications "$app_inside" "$display_name"
        return $?
    fi

    write_log "В ZIP не найден .app или .pkg: $display_name" "ERROR"
    return 1
}

install_local_file() {
    local file="$1"
    local display_name="$2"
    local lower
    lower="$(normalize_name "$file")"

    case "$lower" in
        *.dmg)
            install_dmg "$file" "$display_name"
            return $?
            ;;
        *.pkg)
            install_pkg "$file" "$display_name"
            return $?
            ;;
        *.zip)
            install_zip "$file" "$display_name"
            return $?
            ;;
        *)
            write_log "Неподдерживаемый формат файла для macOS: $file" "ERROR"
            return 1
            ;;
    esac
}

install_app_from_github_release() {
    local display_name="$1"
    local app_name="$2"
    local pkg_id="$3"
    local patterns="$4"
    local allowed_ext_regex='\.(dmg|pkg|zip)$'

    write_log "=============================="
    write_log "Проверяю: $display_name"

    if is_installed "$display_name" "$app_name" "$pkg_id"; then
        return 0
    fi

    local url
    url="$(select_asset_url "$display_name" "$patterns" "$allowed_ext_regex" "$RELEASE_URLS")"

    if [ -z "$url" ]; then
        write_log "Пропускаю: $display_name" "WARN"
        return 1
    fi

    local file_name local_file
    file_name="$(basename "$url")"
    local_file="$DOWNLOAD_DIR/$file_name"

    if ! download_file "$url" "$local_file" "$display_name"; then
        return 1
    fi

    install_local_file "$local_file" "$display_name"
    local code=$?

    if [ $code -eq 0 ]; then
        write_log "Готово: $display_name" "SUCCESS"
    else
        write_log "Не удалось установить: $display_name" "ERROR"
    fi

    return $code
}

main() {
    write_log "=== Старт установки onboarding ПО для macOS ==="
    write_log "GitHub: ${GITHUB_OWNER}/${GITHUB_REPO}, tag: ${GITHUB_TAG}"
    write_log "Лог файл: $LOG_FILE"

    check_required_commands
    check_macos
    check_sudo

    RELEASE_URLS="$(get_release_asset_urls)"

    if [ -z "$RELEASE_URLS" ]; then
        write_log "Не удалось получить список файлов из GitHub Release или Release пустой." "ERROR"
        exit 1
    fi

    write_log "Файлы GitHub Release получены." "SUCCESS"

    install_app_from_github_release \
        "Adobe Acrobat Reader / PDF Reader" \
        "Adobe Acrobat Reader" \
        "com.adobe.acrobat.DC.reader.app.pkg.MUI" \
        "acrobat|adobe.*reader|reader|pdf"

    install_app_from_github_release \
        "Microsoft Office 365" \
        "Microsoft Word" \
        "com.microsoft.package.Microsoft_Office" \
        "microsoft.*office|office.*installer|office|microsoft.*365|365"

    install_app_from_github_release \
        "KeePassXC" \
        "KeePassXC" \
        "" \
        "keepassxc|keepass"

    install_app_from_github_release \
        "Freelens" \
        "Freelens" \
        "" \
        "freelens"

    install_app_from_github_release \
        "Slack" \
        "Slack" \
        "" \
        "slack"

    install_app_from_github_release \
        "Docker Desktop" \
        "Docker" \
        "com.docker.pkg.docker" \
        "docker.*desktop|docker"

    install_app_from_github_release \
        "Postman" \
        "Postman" \
        "" \
        "postman"

    install_app_from_github_release \
        "Telegram" \
        "Telegram" \
        "" \
        "telegram"

    install_app_from_github_release \
        "OpenVPN Connect" \
        "OpenVPN Connect" \
        "net.openvpn.client.app" \
        "openvpn.*connect|openvpn"

    if [ "$SKIP_FORTIVPN" = false ]; then
        install_app_from_github_release \
            "FortiVPN / FortiClient VPN" \
            "FortiClient" \
            "com.fortinet.forticlient" \
            "forti.*client|forti.*vpn|forticlient|fortivpn"
    else
        write_log "FortiVPN пропущен параметром --skip-fortivpn" "WARN"
    fi

    if [ "$SKIP_YANDEX_TELEMOST" = false ]; then
        install_app_from_github_release \
            "Яндекс Телемост" \
            "Телемост" \
            "" \
            "telem|telemost|yandex.*telemost|yandex.*meet|яндекс|телемост"
    else
        write_log "Яндекс Телемост пропущен параметром --skip-yandex-telemost" "WARN"
    fi

    write_log "=============================="
    write_log "Проверка установленных приложений в /Applications"

    for app in \
        "Adobe Acrobat Reader" \
        "Microsoft Word" \
        "KeePassXC" \
        "Freelens" \
        "Slack" \
        "Docker" \
        "Postman" \
        "Telegram" \
        "OpenVPN Connect" \
        "FortiClient" \
        "Телемост"
    do
        if app_exists "$app"; then
            write_log "OK: $app" "SUCCESS"
        else
            write_log "Не найдено в /Applications: $app" "WARN"
        fi
    done

    write_log "Установка завершена." "SUCCESS"
    write_log "Лог находится здесь: $LOG_FILE"
   
}

main
exit 0
