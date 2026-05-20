#!/bin/zsh
# Установка лицензионного ПО для онбординга новых сотрудников на macOS

set +e

LOG_DIR="$HOME/Library/Logs/OnboardingInstall"
LOG_FILE="$LOG_DIR/install-log.txt"

MIN_MACOS_VERSION="26.2"
INSTALL_DOCKER_DESKTOP=true

mkdir -p "$LOG_DIR"

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

    write_log "Homebrew готов к установке программ."
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
    fi

    write_log "Первая попытка не удалась: $display_name"
    write_log "Пробую переустановить с очисткой."

    brew uninstall --cask "$cask_name" --force >> "$LOG_FILE" 2>&1
    brew cleanup "$cask_name" >> "$LOG_FILE" 2>&1
    brew install --cask "$cask_name" --no-quarantine >> "$LOG_FILE" 2>&1

    if [ $? -eq 0 ]; then
        write_log "УСПЕШНО после повторной попытки: $display_name"
        return 0
    else
        write_log "ОШИБКА установки: $display_name"
        return 1
    fi
}

install_microsoft_office() {
    write_log "Начинаю установку Microsoft Office."

    local conflicts=(
        "microsoft-word"
        "microsoft-excel"
        "microsoft-powerpoint"
        "microsoft-outlook"
        "microsoft-onenote"
        "onedrive"
        "microsoft-teams"
        "microsoft-auto-update"
    )

    for app in "${conflicts[@]}"; do
        brew list --cask "$app" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            write_log "Найден конфликтующий Microsoft cask: $app"
            write_log "Удаляю конфликтующий cask: $app"
            brew uninstall --cask "$app" --force >> "$LOG_FILE" 2>&1
        fi
    done

    install_brew_cask "Microsoft Office / Microsoft 365 Apps" "microsoft-office"

    if [ -d "/Applications/Microsoft Word.app" ] || [ -d "/Applications/Microsoft Excel.app" ]; then
        write_log "Microsoft Office установлен."
        return 0
    else
        write_log "Microsoft Office не найден в /Applications после установки."
        return 1
    fi
}

install_forticlient_vpn() {
    write_log "Начинаю установку FortiClient VPN."

    load_homebrew_path

    brew list --cask forticlient-vpn >/dev/null 2>&1

    if [ $? -ne 0 ]; then
        write_log "Устанавливаю FortiClient VPN через Homebrew."
        brew install --cask forticlient-vpn --no-quarantine >> "$LOG_FILE" 2>&1
    else
        write_log "FortiClient VPN cask уже установлен."
    fi

    if [ -d "/Applications/FortiClient.app" ]; then
        write_log "FortiClient VPN установлен: /Applications/FortiClient.app"
        return 0
    fi

    write_log "Ищу FortiClient installer/update app."

    local forti_installer
    forti_installer="$(find /Applications /opt/homebrew/Caskroom /usr/local/Caskroom -iname "FortiClientUpdate.app" -type d 2>/dev/null | head -n 1)"

    if [ -n "$forti_installer" ]; then
        write_log "Найден FortiClientUpdate.app: $forti_installer"
        write_log "Запускаю FortiClientUpdate.app."

        open "$forti_installer"

        write_log "FortiClientUpdate.app открыт. Заверши установку в появившемся окне."
        write_log "После установки FortiClient может запросить разрешения в Privacy & Security."
        return 0
    fi

    local forti_pkg
    forti_pkg="$(find /Applications /opt/homebrew/Caskroom /usr/local/Caskroom -iname "*Forti*.pkg" -type f 2>/dev/null | head -n 1)"

    if [ -n "$forti_pkg" ]; then
        write_log "Найден FortiClient pkg: $forti_pkg"
        write_log "Устанавливаю pkg через installer."

        sudo installer -pkg "$forti_pkg" -target / >> "$LOG_FILE" 2>&1

        if [ $? -eq 0 ]; then
            write_log "FortiClient VPN установлен через pkg."
            return 0
        else
            write_log "ОШИБКА установки FortiClient pkg."
            return 1
        fi
    fi

    if [ -d "/Applications/FortiClient.app" ]; then
        write_log "FortiClient VPN установлен."
        return 0
    else
        write_log "ОШИБКА: FortiClient VPN не установлен автоматически."
        write_log "Проверь лог: $LOG_FILE"
        return 1
    fi
}

install_applications() {
    install_brew_cask "Adobe Acrobat Reader" "adobe-acrobat-reader"

    install_microsoft_office

    install_brew_cask "KeePassXC" "keepassxc"
    install_brew_cask "Freelens" "freelens"
    install_brew_cask "Slack" "slack"
    install_brew_cask "Postman" "postman"
    install_brew_cask "Telegram" "telegram"
    install_brew_cask "Яндекс Телемост" "yandextelemost"
    install_brew_cask "OpenVPN Connect" "openvpn-connect"

    install_forticlient_vpn

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
