#!/bin/zsh
# Установка лицензионного ПО для онбординга новых сотрудников на macOS

set +e

LOG_DIR="$HOME/Library/Logs/OnboardingInstall"
LOG_FILE="$LOG_DIR/install-log.txt"
WORK_DIR="/tmp/onboarding-install"

MIN_MACOS_VERSION="26.2"
INSTALL_DOCKER_DESKTOP=true

OFFICE_URL="https://res.public.onecdn.static.microsoft/mro1cdnstorage/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/Microsoft_365_and_Office_16.109.26051717_Installer.pkg"
OFFICE_PKG="$WORK_DIR/Microsoft_Office_Installer.pkg"

mkdir -p "$LOG_DIR"
mkdir -p "$WORK_DIR"

write_log() {
    local message="$1"
    local time
    time="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$time] $message" | tee -a "$LOG_FILE"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

load_homebrew_path() {
    if [ -x "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi

    if [ -x "/usr/local/bin/brew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
}

version_ge() {
    local current="$1"
    local required="$2"

    local current_major current_minor current_patch
    local required_major required_minor required_patch

    current_major="$(echo "$current" | cut -d. -f1)"
    current_minor="$(echo "$current" | cut -d. -f2)"
    current_patch="$(echo "$current" | cut -d. -f3)"

    required_major="$(echo "$required" | cut -d. -f1)"
    required_minor="$(echo "$required" | cut -d. -f2)"
    required_patch="$(echo "$required" | cut -d. -f3)"

    current_minor="${current_minor:-0}"
    current_patch="${current_patch:-0}"
    required_minor="${required_minor:-0}"
    required_patch="${required_patch:-0}"

    if (( current_major > required_major )); then
        return 0
    elif (( current_major < required_major )); then
        return 1
    fi

    if (( current_minor > required_minor )); then
        return 0
    elif (( current_minor < required_minor )); then
        return 1
    fi

    if (( current_patch >= required_patch )); then
        return 0
    else
        return 1
    fi
}

update_macos_if_needed() {
    local version
    version="$(sw_vers -productVersion)"

    write_log "Текущая версия macOS: $version"
    write_log "Минимальная требуемая версия macOS: $MIN_MACOS_VERSION"

    if version_ge "$version" "$MIN_MACOS_VERSION"; then
        write_log "macOS подходит. Обновление не требуется."
        return 0
    fi

    write_log "macOS ниже $MIN_MACOS_VERSION. Запускаю обновление системы."

    sudo softwareupdate --list >> "$LOG_FILE" 2>&1

    write_log "Устанавливаю все доступные обновления macOS."
    write_log "После обновления Mac может перезагрузиться."

    sudo softwareupdate --install --all --restart >> "$LOG_FILE" 2>&1

    local result=$?

    if [ $result -eq 0 ]; then
        write_log "Обновление macOS запущено."
        write_log "После перезагрузки запусти этот же скрипт повторно."
        exit 0
    else
        write_log "ОШИБКА: macOS не удалось обновить автоматически."
        write_log "Открой System Settings -> General -> Software Update и обнови вручную."
        write_log "Лог: $LOG_FILE"
        exit 1
    fi
}

install_xcode_cli_tools_if_needed() {
    if xcode-select -p >/dev/null 2>&1; then
        write_log "Xcode Command Line Tools уже установлены."
        return 0
    fi

    write_log "Xcode Command Line Tools не найдены. Запускаю установку."

    xcode-select --install >/dev/null 2>&1

    write_log "Открылось окно установки Xcode Command Line Tools."
    write_log "Заверши установку и потом запусти скрипт повторно."

    exit 1
}

install_rosetta_if_needed() {
    if [ "$(uname -m)" != "arm64" ]; then
        write_log "Rosetta не нужна. Это не Apple Silicon."
        return 0
    fi

    if /usr/bin/pgrep oahd >/dev/null 2>&1; then
        write_log "Rosetta уже установлена."
        return 0
    fi

    write_log "Apple Silicon обнаружен. Устанавливаю Rosetta 2."

    sudo /usr/sbin/softwareupdate --install-rosetta --agree-to-license >> "$LOG_FILE" 2>&1

    if [ $? -eq 0 ]; then
        write_log "Rosetta 2 установлена."
    else
        write_log "Rosetta 2 не установилась или уже была установлена."
    fi
}

install_homebrew_if_needed() {
    load_homebrew_path

    if command_exists brew; then
        write_log "Homebrew найден: $(command -v brew)"
        return 0
    fi

    write_log "Homebrew не найден. Устанавливаю Homebrew."

    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" >> "$LOG_FILE" 2>&1

    load_homebrew_path

    if command_exists brew; then
        write_log "Homebrew установлен: $(command -v brew)"
    else
        write_log "ОШИБКА: Homebrew не установился."
        write_log "Лог: $LOG_FILE"
        exit 1
    fi
}

prepare_homebrew() {
    load_homebrew_path

    write_log "Обновляю Homebrew."
    brew update >> "$LOG_FILE" 2>&1

    write_log "Homebrew готов."
}

install_brew_cask() {
    local display_name="$1"
    local cask_name="$2"

    load_homebrew_path

    write_log "Проверяю: $display_name"

    brew list --cask "$cask_name" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        write_log "Уже установлено: $display_name"
        return 0
    fi

    write_log "Устанавливаю: $display_name"

    brew install --cask "$cask_name" --no-quarantine >> "$LOG_FILE" 2>&1

    if [ $? -eq 0 ]; then
        write_log "УСПЕШНО: $display_name"
        return 0
    else
        write_log "ОШИБКА установки: $display_name"
        return 1
    fi
}

install_microsoft_office_direct_pkg() {
    write_log "Начинаю установку Microsoft Office напрямую через официальный pkg."

    if [ -d "/Applications/Microsoft Word.app" ] && [ -d "/Applications/Microsoft Excel.app" ] && [ -d "/Applications/Microsoft PowerPoint.app" ]; then
        write_log "Microsoft Office уже установлен."
        return 0
    fi

    write_log "Скачиваю Microsoft Office pkg."
    rm -f "$OFFICE_PKG"

    curl -L --fail --connect-timeout 30 --retry 3 --retry-delay 10 -o "$OFFICE_PKG" "$OFFICE_URL" >> "$LOG_FILE" 2>&1

    if [ $? -ne 0 ]; then
        write_log "ОШИБКА: не удалось скачать Microsoft Office pkg."
        write_log "Проверь интернет, DNS или доступ к Microsoft CDN."
        return 1
    fi

    if [ ! -s "$OFFICE_PKG" ]; then
        write_log "ОШИБКА: Microsoft Office pkg скачался пустым файлом."
        return 1
    fi

    write_log "Устанавливаю Microsoft Office pkg через installer."

    sudo installer -pkg "$OFFICE_PKG" -target / >> "$LOG_FILE" 2>&1

    if [ $? -ne 0 ]; then
        write_log "ОШИБКА: installer не смог установить Microsoft Office."
        return 1
    fi

    if [ -d "/Applications/Microsoft Word.app" ] || [ -d "/Applications/Microsoft Excel.app" ]; then
        write_log "УСПЕШНО: Microsoft Office установлен."
        return 0
    else
        write_log "ОШИБКА: Microsoft Office не найден в /Applications после установки."
        return 1
    fi
}

install_forticlient_vpn() {
    write_log "Начинаю установку FortiClient VPN."

    if [ -d "/Applications/FortiClient.app" ]; then
        write_log "FortiClient уже установлен."
        return 0
    fi

    load_homebrew_path

    write_log "Пробую установить FortiClient VPN через Homebrew cask."

    brew install --cask forticlient-vpn --no-quarantine >> "$LOG_FILE" 2>&1

    if [ -d "/Applications/FortiClient.app" ]; then
        write_log "УСПЕШНО: FortiClient VPN установлен."
        return 0
    fi

    write_log "FortiClient.app пока не найден. Ищу FortiClientUpdate.app или Install.app."

    local forti_app
    forti_app="$(find /Applications /opt/homebrew/Caskroom /usr/local/Caskroom "$HOME/Downloads" -iname "FortiClientUpdate.app" -type d 2>/dev/null | head -n 1)"

    if [ -z "$forti_app" ]; then
        forti_app="$(find /Applications /opt/homebrew/Caskroom /usr/local/Caskroom "$HOME/Downloads" -iname "Install.app" -type d 2>/dev/null | grep -i Forti | head -n 1)"
    fi

    if [ -n "$forti_app" ]; then
        write_log "Найден установщик FortiClient: $forti_app"
        write_log "Открываю установщик FortiClient. Заверши установку в окне."

        open "$forti_app"

        write_log "ВАЖНО: после установки FortiClient может попросить разрешения в System Settings -> Privacy & Security."
        return 0
    fi

    write_log "ОШИБКА: FortiClient VPN не удалось установить автоматически."
    write_log "Причина обычно в том, что Fortinet использует online-installer, который не всегда работает в silent-режиме."
    write_log "Скачай FortiClient VPN для macOS с сайта Fortinet или положи DMG/PKG рядом со скриптом."
    return 1
}

install_local_forti_if_exists() {
    write_log "Проверяю локальный FortiClient installer рядом со скриптом."

    local script_dir
    script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

    local local_pkg
    local local_dmg

    local_pkg="$(find "$script_dir" "$WORK_DIR" "$HOME/Downloads" -maxdepth 1 -iname "*Forti*.pkg" -type f 2>/dev/null | head -n 1)"
    local_dmg="$(find "$script_dir" "$WORK_DIR" "$HOME/Downloads" -maxdepth 1 -iname "*Forti*.dmg" -type f 2>/dev/null | head -n 1)"

    if [ -n "$local_pkg" ]; then
        write_log "Найден локальный FortiClient pkg: $local_pkg"
        sudo installer -pkg "$local_pkg" -target / >> "$LOG_FILE" 2>&1

        if [ $? -eq 0 ]; then
            write_log "УСПЕШНО: FortiClient установлен из локального pkg."
            return 0
        else
            write_log "ОШИБКА: локальный FortiClient pkg не установился."
            return 1
        fi
    fi

    if [ -n "$local_dmg" ]; then
        write_log "Найден локальный FortiClient dmg: $local_dmg"
        write_log "Монтирую dmg."

        local mount_point
        mount_point="$(hdiutil attach "$local_dmg" -nobrowse -quiet | grep "/Volumes/" | sed 's/^.*\/Volumes\//\/Volumes\//' | head -n 1)"

        if [ -z "$mount_point" ]; then
            write_log "ОШИБКА: не удалось смонтировать FortiClient dmg."
            return 1
        fi

        local pkg_in_dmg
        local app_in_dmg

        pkg_in_dmg="$(find "$mount_point" -iname "*Forti*.pkg" -type f 2>/dev/null | head -n 1)"
        app_in_dmg="$(find "$mount_point" -iname "Install.app" -type d 2>/dev/null | head -n 1)"

        if [ -n "$pkg_in_dmg" ]; then
            write_log "Найден pkg внутри dmg: $pkg_in_dmg"
            sudo installer -pkg "$pkg_in_dmg" -target / >> "$LOG_FILE" 2>&1
            hdiutil detach "$mount_point" -quiet >> "$LOG_FILE" 2>&1
            return 0
        fi

        if [ -n "$app_in_dmg" ]; then
            write_log "Найден Install.app внутри dmg: $app_in_dmg"
            open "$app_in_dmg"
            write_log "Заверши установку FortiClient в открывшемся окне."
            return 0
        fi

        hdiutil detach "$mount_point" -quiet >> "$LOG_FILE" 2>&1
    fi

    write_log "Локальный FortiClient installer не найден."
    return 1
}

install_applications() {
    install_brew_cask "Adobe Acrobat Reader" "adobe-acrobat-reader"

    install_microsoft_office_direct_pkg

    install_brew_cask "KeePassXC" "keepassxc"
    install_brew_cask "Freelens" "freelens"
    install_brew_cask "Slack" "slack"
    install_brew_cask "Postman" "postman"
    install_brew_cask "Telegram" "telegram"
    install_brew_cask "Яндекс Телемост" "yandextelemost"
    install_brew_cask "OpenVPN Connect" "openvpn-connect"

    install_local_forti_if_exists
    if [ $? -ne 0 ]; then
        install_forticlient_vpn
    fi

    if [ "$INSTALL_DOCKER_DESKTOP" = true ]; then
        install_brew_cask "Docker Desktop" "docker-desktop"
    else
        write_log "Docker Desktop пропущен."
    fi
}

write_log "=========================================="
write_log "Старт установки onboarding ПО для macOS"
write_log "Лог: $LOG_FILE"

update_macos_if_needed
install_xcode_cli_tools_if_needed
install_rosetta_if_needed
install_homebrew_if_needed
prepare_homebrew
install_applications

write_log "=========================================="
write_log "Установка завершена."
write_log "Лог: $LOG_FILE"

exit 0
