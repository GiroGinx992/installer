#!/bin/zsh
# Полное удаление Microsoft Office / Microsoft 365 с macOS

set +e

LOG_DIR="$HOME/Library/Logs/OfficeRemove"
LOG_FILE="$LOG_DIR/remove-office-log.txt"

mkdir -p "$LOG_DIR"

write_log() {
    local message="$1"
    local time
    time="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$time] $message" | tee -a "$LOG_FILE"
}

remove_path() {
    local path="$1"

    if [ -e "$path" ] || [ -L "$path" ]; then
        write_log "Удаляю: $path"
        rm -rf "$path" >> "$LOG_FILE" 2>&1
    else
        write_log "Не найдено, пропускаю: $path"
    fi
}

remove_sudo_path() {
    local path="$1"

    if [ -e "$path" ] || [ -L "$path" ]; then
        write_log "Удаляю через sudo: $path"
        sudo rm -rf "$path" >> "$LOG_FILE" 2>&1
    else
        write_log "Не найдено, пропускаю: $path"
    fi
}

write_log "=========================================="
write_log "Старт полного удаления Microsoft Office"
write_log "Лог: $LOG_FILE"

write_log "Закрываю приложения Microsoft Office"

osascript -e 'quit app "Microsoft Word"' >/dev/null 2>&1
osascript -e 'quit app "Microsoft Excel"' >/dev/null 2>&1
osascript -e 'quit app "Microsoft PowerPoint"' >/dev/null 2>&1
osascript -e 'quit app "Microsoft Outlook"' >/dev/null 2>&1
osascript -e 'quit app "Microsoft OneNote"' >/dev/null 2>&1
osascript -e 'quit app "OneDrive"' >/dev/null 2>&1
osascript -e 'quit app "Microsoft Teams"' >/dev/null 2>&1
osascript -e 'quit app "Microsoft AutoUpdate"' >/dev/null 2>&1

pkill -f "Microsoft Word" >/dev/null 2>&1
pkill -f "Microsoft Excel" >/dev/null 2>&1
pkill -f "Microsoft PowerPoint" >/dev/null 2>&1
pkill -f "Microsoft Outlook" >/dev/null 2>&1
pkill -f "Microsoft OneNote" >/dev/null 2>&1
pkill -f "Microsoft AutoUpdate" >/dev/null 2>&1
pkill -f "OneDrive" >/dev/null 2>&1
pkill -f "Teams" >/dev/null 2>&1

write_log "Удаляю приложения из /Applications"

remove_sudo_path "/Applications/Microsoft Word.app"
remove_sudo_path "/Applications/Microsoft Excel.app"
remove_sudo_path "/Applications/Microsoft PowerPoint.app"
remove_sudo_path "/Applications/Microsoft Outlook.app"
remove_sudo_path "/Applications/Microsoft OneNote.app"
remove_sudo_path "/Applications/OneDrive.app"
remove_sudo_path "/Applications/Microsoft Teams.app"
remove_sudo_path "/Applications/Microsoft Teams classic.app"
remove_sudo_path "/Applications/Microsoft AutoUpdate.app"

write_log "Удаляю пользовательские Office Containers"

remove_path "$HOME/Library/Containers/com.microsoft.Word"
remove_path "$HOME/Library/Containers/com.microsoft.Excel"
remove_path "$HOME/Library/Containers/com.microsoft.Powerpoint"
remove_path "$HOME/Library/Containers/com.microsoft.PowerPoint"
remove_path "$HOME/Library/Containers/com.microsoft.Outlook"
remove_path "$HOME/Library/Containers/com.microsoft.onenote.mac"
remove_path "$HOME/Library/Containers/com.microsoft.OneNote"
remove_path "$HOME/Library/Containers/com.microsoft.OneDrive-mac"
remove_path "$HOME/Library/Containers/com.microsoft.teams"
remove_path "$HOME/Library/Containers/com.microsoft.RMS-XPCService"
remove_path "$HOME/Library/Containers/com.microsoft.errorreporting"
remove_path "$HOME/Library/Containers/com.microsoft.Office365ServiceV2"
remove_path "$HOME/Library/Containers/com.microsoft.netlib.shipassertprocess"

write_log "Удаляю Office Group Containers"

remove_path "$HOME/Library/Group Containers/UBF8T346G9.ms"
remove_path "$HOME/Library/Group Containers/UBF8T346G9.Office"
remove_path "$HOME/Library/Group Containers/UBF8T346G9.OfficeOsfWebHost"
remove_path "$HOME/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite"
remove_path "$HOME/Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite"

write_log "Удаляю настройки Microsoft Office"

remove_path "$HOME/Library/Preferences/com.microsoft.Word.plist"
remove_path "$HOME/Library/Preferences/com.microsoft.Excel.plist"
remove_path "$HOME/Library/Preferences/com.microsoft.Powerpoint.plist"
remove_path "$HOME/Library/Preferences/com.microsoft.PowerPoint.plist"
remove_path "$HOME/Library/Preferences/com.microsoft.Outlook.plist"
remove_path "$HOME/Library/Preferences/com.microsoft.onenote.mac.plist"
remove_path "$HOME/Library/Preferences/com.microsoft.OneDrive.plist"
remove_path "$HOME/Library/Preferences/com.microsoft.autoupdate2.plist"
remove_path "$HOME/Library/Preferences/com.microsoft.office.plist"
remove_path "$HOME/Library/Preferences/com.microsoft.office.setupassistant.plist"

write_log "Удаляю кэши Microsoft Office"

remove_path "$HOME/Library/Caches/com.microsoft.Word"
remove_path "$HOME/Library/Caches/com.microsoft.Excel"
remove_path "$HOME/Library/Caches/com.microsoft.Powerpoint"
remove_path "$HOME/Library/Caches/com.microsoft.PowerPoint"
remove_path "$HOME/Library/Caches/com.microsoft.Outlook"
remove_path "$HOME/Library/Caches/com.microsoft.onenote.mac"
remove_path "$HOME/Library/Caches/com.microsoft.autoupdate2"
remove_path "$HOME/Library/Caches/com.microsoft.teams"

write_log "Удаляю LaunchAgents и системные компоненты Microsoft"

remove_sudo_path "/Library/LaunchAgents/com.microsoft.update.agent.plist"
remove_sudo_path "/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist"
remove_sudo_path "/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper"
remove_sudo_path "/Library/Application Support/Microsoft"
remove_sudo_path "/Library/Preferences/com.microsoft.office.licensingV2.plist"
remove_sudo_path "/Library/Preferences/com.microsoft.autoupdate2.plist"

write_log "Удаляю Office pkg receipts"

for receipt in $(pkgutil --pkgs | grep -i "com.microsoft" | grep -Ei "office|word|excel|powerpoint|outlook|onenote|autoupdate|licensing|onedrive|teams"); do
    write_log "Удаляю receipt: $receipt"
    sudo pkgutil --forget "$receipt" >> "$LOG_FILE" 2>&1
done

write_log "Проверяю остатки приложений"

ls /Applications | grep -i "Microsoft" >> "$LOG_FILE" 2>&1

write_log "=========================================="
write_log "Удаление Microsoft Office завершено"
write_log "Рекомендуется перезагрузить Mac"
write_log "Лог: $LOG_FILE"

exit 0
