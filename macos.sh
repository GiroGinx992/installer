#!/bin/zsh

set +e

BASE_DIR="$HOME/Library/Application Support/OnboardingInstaller"
LOG_DIR="$HOME/Library/Logs/OnboardingInstaller"
LOG_FILE="$LOG_DIR/install-macos-homebrew.log"

mkdir -p "$BASE_DIR" "$LOG_DIR"

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
write_log "macOS Homebrew Interactive Installer"
write_log "macOS version: $MACOS_VERSION"
write_log "Architecture: $ARCH"
write_log "Log file: $LOG_FILE"
write_log "============================================================"

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

clt_installed() {
    if xcode-select -p >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

install_clt_softwareupdate() {
    write_log "Пробую установить Xcode Command Line Tools через softwareupdate..."

    sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

    local label
    label="$(softwareupdate -l 2>/dev/null \
        | grep -B 1 -E "Command Line Tools" \
        | awk -F"*" '/\*/ {print $2}' \
        | sed 's/^ *//;s/ *$//' \
        | tail -n 1)"

    if [[ -z "$label" ]]; then
        write_log "softwareupdate не нашёл Command Line Tools." "WARN"
        sudo rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
        return 1
    fi

    write_log "Найден пакет: $label"
    sudo softwareupdate -i "$label" --verbose

    local code=$?

    sudo rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

    if [[ "$code" -eq 0 ]] && clt_installed; then
        write_log "Xcode Command Line Tools установлены через softwareupdate." "SUCCESS"
        return 0
    fi

    write_log "Установка Command Line Tools через softwareupdate не завершилась успешно. Код: $code" "WARN"
    return 1
}

install_clt_gui() {
    write_log "Запускаю стандартную установку Xcode Command Line Tools через xcode-select --install." "WARN"
    write_log "На экране macOS появится окно установки. Нужно нажать Install / Установить." "WARN"

    xcode-select --install >/dev/null 2>&1

    write_log "Ожидаю завершения установки Command Line Tools..."

    local waited=0
    local max_wait=3600

    while [[ "$waited" -lt "$max_wait" ]]; do
        if clt_installed; then
            write_log "Xcode Command Line Tools установлены." "SUCCESS"
            return 0
        fi

        sleep 10
        waited=$((waited + 10))
        write_log "Ожидание Command Line Tools: ${waited}s / ${max_wait}s"
    done

    write_log "Command Line Tools не установились за отведённое время." "ERROR"
    return 1
}

ensure_clt() {
    if clt_installed; then
        local path
        path="$(xcode-select -p 2>/dev/null)"
        write_log "Xcode Command Line Tools найдены: $path" "SUCCESS"
        return 0
    fi

    write_log "Xcode Command Line Tools не найдены." "WARN"

    install_clt_softwareupdate

    if clt_installed; then
        return 0
    fi

    install_clt_gui

    if clt_installed; then
        return 0
    fi

    write_log "Не удалось установить Xcode Command Line Tools. Homebrew может не установиться." "ERROR"
    exit 1
}

setup_brew_path() {
    if [[ -x "/opt/homebrew/bin/brew" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi

    if [[ -x "/usr/local/bin/brew" ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    if [[ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]]; then
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    fi
}

brew_installed() {
    setup_brew_path

    if command_exists brew; then
        return 0
    fi

    return 1
}

install_homebrew() {
    if brew_installed; then
        write_log "Homebrew уже установлен: $(command -v brew)" "SUCCESS"
        return 0
    fi

    write_log "Homebrew не найден. Начинаю установку Homebrew..." "WARN"
    write_log "Официальный install script: https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    local code=$?

    setup_brew_path

    if [[ "$code" -eq 0 ]] && brew_installed; then
        write_log "Homebrew установлен: $(command -v brew)" "SUCCESS"
        add_brew_to_shell_profile
        return 0
    fi

    write_log "Homebrew не установился. Код: $code" "ERROR"
    exit 1
}

add_brew_to_shell_profile() {
    local brew_bin
    brew_bin="$(command -v brew 2>/dev/null)"

    if [[ -z "$brew_bin" ]]; then
        return 1
    fi

    local brew_prefix
    brew_prefix="$(brew --prefix 2>/dev/null)"

    if [[ -z "$brew_prefix" ]]; then
        return 1
    fi

    local shellenv_line="eval \"\$(${brew_prefix}/bin/brew shellenv)\""

    if [[ ! -f "$HOME/.zprofile" ]]; then
        touch "$HOME/.zprofile"
    fi

    if ! grep -Fq "$shellenv_line" "$HOME/.zprofile"; then
        echo "$shellenv_line" >> "$HOME/.zprofile"
        write_log "Homebrew PATH добавлен в ~/.zprofile" "SUCCESS"
    else
        write_log "Homebrew PATH уже есть в ~/.zprofile"
    fi

    eval "$(${brew_prefix}/bin/brew shellenv)"
}

ensure_homebrew() {
    if brew_installed; then
        write_log "Homebrew найден: $(command -v brew)" "SUCCESS"
        add_brew_to_shell_profile
        return 0
    fi

    install_homebrew
}

brew_update_once() {
    write_log "Обновляю Homebrew..."
    brew update
    local code=$?

    if [[ "$code" -eq 0 ]]; then
        write_log "brew update завершён." "SUCCESS"
    else
        write_log "brew update завершился с кодом: $code" "WARN"
    fi
}

app_exists() {
    local app_name="$1"

    if [[ -d "/Applications/$app_name.app" ]]; then
        return 0
    fi

    if [[ -d "$HOME/Applications/$app_name.app" ]]; then
        return 0
    fi

    return 1
}

cask_installed() {
    local cask="$1"
    brew list --cask "$cask" >/dev/null 2>&1
    return $?
}

cask_available() {
    local cask="$1"
    brew info --cask "$cask" >/dev/null 2>&1
    return $?
}

install_cask() {
    local display_name="$1"
    local cask="$2"
    local app_name="$3"

    write_log "============================================================"
    write_log "Проверяю: $display_name"
    write_log "Cask: $cask"

    if [[ -n "$app_name" ]] && app_exists "$app_name"; then
        write_log "Уже установлено в /Applications: $app_name.app" "SUCCESS"
        return 0
    fi

    if cask_installed "$cask"; then
        write_log "Cask уже установлен: $cask" "SUCCESS"
        return 0
    fi

    if ! cask_available "$cask"; then
        write_log "Cask не найден в Homebrew: $cask" "ERROR"
        return 1
    fi

    write_log "Устанавливаю через Homebrew Cask: $display_name"

    brew install --cask "$cask" --no-quarantine

    local code=$?

    if [[ "$code" -eq 0 ]]; then
        write_log "Успешно установлено: $display_name" "SUCCESS"
        return 0
    fi

    write_log "Ошибка установки $display_name. Код brew: $code" "ERROR"
    return 1
}

show_manual_urls() {
    echo ""
    echo "============================================================"
    echo "Программы, которые лучше проверить/установить вручную"
    echo "============================================================"
    echo "FortiVPN / FortiClient VPN:"
    echo "  https://www.fortinet.com/support/product-downloads"
    echo ""
    echo "Яндекс Телемост:"
    echo "  https://telemost.yandex.ru/"
    echo ""
    echo "Adobe Acrobat Reader:"
    echo "  https://get.adobe.com/reader/"
    echo ""
    echo "Microsoft Office для Mac не устанавливается по твоему требованию."
    echo "============================================================"
}

show_menu() {
    clear
    echo "============================================================"
    echo " macOS Homebrew Interactive Installer"
    echo "============================================================"
    echo " macOS: $MACOS_VERSION"
    echo " Arch : $ARCH"
    echo " Brew : $(command -v brew 2>/dev/null)"
    echo " Log  : $LOG_FILE"
    echo "============================================================"
    echo ""
    echo "Выбери программу:"
    echo ""
    echo " 1) Docker Desktop"
    echo " 2) Slack"
    echo " 3) Telegram"
    echo " 4) Postman"
    echo " 5) OpenVPN Connect"
    echo " 6) KeePassXC"
    echo " 7) Freelens"
    echo " 8) Adobe Acrobat Reader"
    echo " 9) FortiVPN / FortiClient VPN"
    echo "10) Яндекс Телемост"
    echo ""
    echo "11) Установить всё из списка"
    echo "12) brew update"
    echo "13) Проверить Xcode CLT + Homebrew"
    echo "14) Показать ссылки для ручной установки"
    echo "15) Показать путь к логу"
    echo ""
    echo " 0) Выход"
    echo ""
}

pause_enter() {
    echo ""
    echo "Нажми Enter, чтобы продолжить..."
    read _
}

install_choice() {
    local choice="$1"

    case "$choice" in
        1)
            install_cask "Docker Desktop" "docker" "Docker"
            ;;
        2)
            install_cask "Slack" "slack" "Slack"
            ;;
        3)
            install_cask "Telegram" "telegram" "Telegram"
            ;;
        4)
            install_cask "Postman" "postman" "Postman"
            ;;
        5)
            install_cask "OpenVPN Connect" "openvpn-connect" "OpenVPN Connect"
            ;;
        6)
            install_cask "KeePassXC" "keepassxc" "KeePassXC"
            ;;
        7)
            install_cask "Freelens" "freelens" "Freelens"
            ;;
        8)
            install_cask "Adobe Acrobat Reader" "adobe-acrobat-reader" "Adobe Acrobat Reader"
            ;;
        9)
            install_cask "FortiVPN / FortiClient VPN" "forticlient-vpn" "FortiClient"
            ;;
        10)
            # Cask может отсутствовать в Homebrew. Скрипт проверит.
            install_cask "Яндекс Телемост" "yandex-telemost" "Яндекс Телемост"
            ;;
        *)
            write_log "Некорректный выбор: $choice" "WARN"
            ;;
    esac
}

install_all() {
    local n

    for n in 1 2 3 4 5 6 7 8 9 10; do
        install_choice "$n"
    done

    show_manual_urls
}

final_check() {
    write_log "============================================================"
    write_log "Финальная проверка /Applications"
    write_log "============================================================"

    local apps=(
        "Docker"
        "Slack"
        "Telegram"
        "Postman"
        "OpenVPN Connect"
        "KeePassXC"
        "Freelens"
        "Adobe Acrobat Reader"
        "FortiClient"
        "FortiClient VPN"
        "Яндекс Телемост"
        "Yandex Telemost"
        "Telemost"
    )

    local app
    for app in "${apps[@]}"; do
        if app_exists "$app"; then
            write_log "OK: $app" "SUCCESS"
        else
            write_log "Не найдено в /Applications: $app" "WARN"
        fi
    done
}

# =====================================================================
# START
# =====================================================================

require_sudo

keep_sudo_alive &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1' EXIT

ensure_clt
ensure_homebrew
brew_update_once

while true; do
    show_menu
    echo -n "Введи номер: "
    read choice

    case "$choice" in
        0)
            final_check
            write_log "Выход."
            exit 0
            ;;
        1|2|3|4|5|6|7|8|9|10)
            install_choice "$choice"
            pause_enter
            ;;
        11)
            install_all
            pause_enter
            ;;
        12)
            brew_update_once
            pause_enter
            ;;
        13)
            ensure_clt
            ensure_homebrew
            pause_enter
            ;;
        14)
            show_manual_urls
            pause_enter
            ;;
        15)
            echo ""
            echo "Лог:"
            echo "$LOG_FILE"
            echo ""
            echo "Команда просмотра:"
            echo "tail -n 150 \"$LOG_FILE\""
            pause_enter
            ;;
        *)
            echo "Некорректный выбор."
            pause_enter
            ;;
    esac
done

exit 0
