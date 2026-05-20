#!/bin/zsh
# Назначение: установка лицензионного ПО для онбординга новых сотрудников на macOS

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

version_ge() {
    local current="$1"
    local required="$2"

    local current_major current_minor current_patch
    local required_major required_minor required_patch

    current_major="${current%%.*}"
    current_rest="${current#*.}"

    if [[ "$current_rest" == "$current" ]]; then
        current_minor=0
        current_patch=0
    else
        current_minor="${current_rest%%.*}"
        current_patch="${current_rest#*.}"

        if [[ "$current_patch" == "$current_rest" ]]; then
            current_patch=0
        fi
    fi

    required_major="${required%%.*}"
    required_rest="${required#*.}"

    if [[ "$required_rest" == "$required" ]]; then
        required_minor=0
        required_patch=0
    else
        required_minor="${required_rest%%.*}"
        required_patch="${required_rest#*.}"

        if [[ "$required_patch" == "$required_rest" ]]; then
            required_patch=0
        fi
    fi

    current_major="${current_major:-0}"
    current_minor="${current_minor:-0}"
    current_patch="${current_patch:-0}"

    required_major="${required_major:-0}"
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
        write_log "Проверка версии macOS: OK"
        return
    fi

    write_log "macOS ниже требуемой версии $MIN_MACOS_VERSION."
    write_log "Запускаю поиск доступных обновлений macOS..."

    softwareupdate --list >> "$LOG_FILE" 2>&1

    write_log "Запускаю установку всех доступных обновлений macOS."
    write_log "Может потребоваться пароль администратора и перезагрузка."

    sudo softwareupdate --install --all --restart >> "$LOG_FILE" 2>&1

    update_result=$?

    if [ $update_result -eq 0 ]; then
        write_log "Обновление macOS запущено или установлено."
        write_log "Если Mac не перезагрузился автоматически, перезагрузи его вручную."
        write_log "После обновления запусти этот скрипт повторно."
        exit 0
    else
        write_log "ОШИБКА: не удалось установить обновление macOS."
        write_log "Проверь лог: $LOG_FILE"
        write_log "Также можно вручную открыть: System Settings -> General -> Software Update."
        exit 1
    fi
}

install_xcode_cli_tools_if_needed() {
    if xcode-select -p >/dev/null 2>&1; then
        write_log "Xcode Command Line Tools: OK"
        return
    fi

    write_log "Xcode Command Line Tools не найдены. Запускаю установку."
    xcode-select --install

    write_log "Заверши установку Xcode Command Line Tools в появившемся окне."
    write_log "После завершения запусти скрипт повторно."
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

    write_log "Apple Silicon обнаружен. Устанавливаю Rosetta 2."
    /usr/sbin/softwareupdate --install-rosetta --agree-to-license >> "$LOG_FILE" 2>&1

    if [ $? -eq 0 ]; then
        write_log "Rosetta 2 установлена."
    else
        write_log "Rosetta 2 не установилась или уже была установлена."
    fi
}

load_homebrew_path() {
    if [ -x "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi

    if [ -x "/usr/local/bin/brew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
}

install_homebrew_if_needed() {
    load_homebrew_path

    if command_exists brew; then
        write_log "Homebrew найден: $(command -v brew)"
        return
    fi

    write_log "Homebrew не найден. Устанавливаю Homebrew официальным скриптом."

    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" >> "$LOG_FILE" 2>&1

    load_homebrew_path

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

    write_log "Устанавливаю через Homebrew Cask: $display_name [$cask_name]"

    brew install --cask "$cask_name" >> "$LOG_FILE" 2>&1

    if [ $? -eq 0 ]; then
        write_log "УСПЕШНО: $display_name"
    else
        write_log "ОШИБКА установки: $display_name"
        write_log "Проверь лог: $LOG_FILE"
    fi
}

write_log "=========================================="
write_log "Старт установки onboarding ПО для macOS"

update_macos_if_needed
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
install_brew_cask "FortiClient VPN" "forticlient-vpn"

if [ "$INSTALL_DOCKER_DESKTOP" = true ]; then
    install_brew_cask "Docker Desktop" "docker-desktop"
else
    write_log "Docker Desktop пропущен. Нужно подтвердить лицензию Docker для вашей организации."
fi

write_log "Установка завершена"
write_log "Лог: $LOG_FILE"

exit 0
