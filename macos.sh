#!/bin/zsh
#установка лицензионного ПО для онбординга новых сотрудников на macOS


set +e

LOG_DIR="$HOME/Library/Logs/OnboardingInstall"
LOG_FILE="$LOG_DIR/install-log.txt"


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

check_macos() {
    local version
    version="$(sw_vers -productVersion)"
    write_log "macOS version: $version"
}

install_xcode_cli_tools_if_needed() {
    if xcode-select -p >/dev/null 2>&1; then
        write_log "Xcode Command Line Tools: OK"
        return
    fi

    write_log "Xcode Command Line Tools не найдены. Запускаю установку."
    xcode-select --install

    write_log "заверши установку Xcode Command Line Tools в появившемся окне, затем запусти скрипт повторно."
    exit 1
}

install_rosetta_if_needed() {
    if [ "$(uname -m)" != "arm64" ]; then
        write_log "Rosetta не нужна: Mac не Apple Silicon."
        return
    fi

    if /usr/bin/pgrep oahd >/dev/null 2>&1; then
        write_log "Rosetta: OK"
        return
    fi

    write_log "Apple Silicon обнаружен. Устанавливаю Rosetta 2 на случай Intel-only установщиков."
    /usr/sbin/softwareupdate --install-rosetta --agree-to-license >> "$LOG_FILE" 2>&1

    if [ $? -eq 0 ]; then
        write_log "Rosetta 2 установлена."
    else
        write_log "Rosetta 2 не установилась или уже была установлена."
    fi
}

install_homebrew_if_needed() {
    if command_exists brew; then
        write_log "Homebrew найден: $(command -v brew)"
        return
    fi

    write_log "Homebrew не найден. Устанавливаю Homebrew официальным скриптом."

    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    if [ -x "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi

    if [ -x "/usr/local/bin/brew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    if command_exists brew; then
        write_log "Homebrew установлен: $(command -v brew)"
    else
        write_log "ОШИБКА: Homebrew не удалось установить или он не появился в PATH."
        exit 1
    fi
}

prepare_homebrew() {
    write_log "Обновляю Homebrew..."
    brew update >> "$LOG_FILE" 2>&1

    write_log "Проверяю Homebrew doctor..."
    brew doctor >> "$LOG_FILE" 2>&1
}

install_brew_cask() {
    local display_name="$1"
    local cask_name="$2"

    write_log "Проверяю: $display_name [$cask_name]"

    brew list --cask "$cask_name" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        write_log "Уже установлено: $display_name"
        return
    fi

    write_log "Устанавливаю лицензионное ПО через Homebrew Cask: $display_name [$cask_name]"

    brew install --cask "$cask_name" >> "$LOG_FILE" 2>&1

    if [ $? -eq 0 ]; then
        write_log "УСПЕШНО: $display_name"
    else
        write_log "ОШИБКА установки: $display_name"
    fi
}


write_log "=========================================="
write_log "Старт установки onboarding ПО для macOS"


check_macos
install_xcode_cli_tools_if_needed
install_rosetta_if_needed
install_homebrew_if_needed
prepare_homebrew


install_brew_cask "Adobe Acrobat Reader" "adobe-acrobat-reader"
install_brew_cask "Microsoft Office / Microsoft 365 Apps" "microsoft-office"
install_brew_cask "KeePassXC" "keepassxc"
install_brew_cask "Freelens" "freelens"
install_brew_cask "Slack" "slack"
install_brew_cask "Postman" "postman"
install_brew_cask "Telegram" "telegram"
install_brew_cask "Яндекс Телемост" "yandextelemost"


install_brew_cask "OpenVPN Connect" "openvpn-connect"


if [ "$INSTALL_DOCKER_DESKTOP" = true ]; then
    install_brew_cask "Docker Desktop" "docker-desktop"
else
    write_log "Docker Desktop пропущен. Нужно подтвердить лицензию Docker для вашей организации."
fi

write_log "Установка завершена"
write_log "Лог: $LOG_FILE"


exit 0
