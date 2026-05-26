#Requires -Version 5.1


[CmdletBinding()]
param(
    [string]$GitHubOwner = "GiroGinx992",
    [string]$GitHubRepo  = "installer",
    [string]$GitHubTag   = "onbording-v1",

    [switch]$SkipFortiVPN,
    [switch]$SkipYandexTelemost
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$BaseDir     = Join-Path $env:ProgramData "OnboardingInstaller"
$DownloadDir = Join-Path $BaseDir "downloads"
$LogDir      = Join-Path $BaseDir "logs"
$LogFile     = Join-Path $LogDir "install-windows.log"

New-Item -ItemType Directory -Force -Path $BaseDir, $DownloadDir, $LogDir | Out-Null

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )

    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$time] [$Level] $Message"

    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Log "Скрипт нужно запускать от имени администратора." "ERROR"
    Write-Log "Открой PowerShell от имени администратора и запусти команду повторно." "ERROR"
    exit 1
}

Write-Log "Скрипт запущен от имени администратора." "SUCCESS"
Write-Log "Лог файл: $LogFile"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Log "TLS 1.2 включён."
}
catch {
    Write-Log "Не удалось включить TLS 1.2, продолжаю работу." "WARN"
}

function Get-WingetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue

    if ($cmd) {
        return $cmd.Source
    }

    $localPath = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"

    if (Test-Path $localPath) {
        return $localPath
    }

    $programFilesWindowsApps = Join-Path $env:ProgramFiles "WindowsApps"

    if (Test-Path $programFilesWindowsApps) {
        try {
            $found = Get-ChildItem -Path $programFilesWindowsApps -Filter "winget.exe" -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($found) {
                return $found.FullName
            }
        }
        catch {
            return $null
        }
    }

    return $null
}

function Test-Winget {
    $wingetPath = Get-WingetPath

    if (-not $wingetPath) {
        return $false
    }

    try {
        $version = & $wingetPath --version 2>$null
        if ($LASTEXITCODE -eq 0 -and $version) {
            return $true
        }

        return $false
    }
    catch {
        return $false
    }
}

function Install-WingetUsingMicrosoftModule {
    Write-Log "Пробую установить winget через Microsoft.WinGet.Client..."

    try {
        $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue

        if (-not $nuget) {
            Write-Log "Устанавливаю NuGet provider..."
            Install-PackageProvider -Name NuGet -Force -Scope AllUsers -ErrorAction Stop | Out-Null
        }

        try {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
        }
        catch {
            Write-Log "Не удалось изменить политику PSGallery, продолжаю." "WARN"
        }

        $module = Get-Module -ListAvailable -Name Microsoft.WinGet.Client | Select-Object -First 1

        if (-not $module) {
            Write-Log "Устанавливаю модуль Microsoft.WinGet.Client..."
            Install-Module -Name Microsoft.WinGet.Client -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
        }

        Import-Module Microsoft.WinGet.Client -Force -ErrorAction Stop

        $cmd = Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue

        if (-not $cmd) {
            Write-Log "Команда Repair-WinGetPackageManager недоступна." "WARN"
            return $false
        }

        Write-Log "Восстанавливаю/устанавливаю winget вместе с зависимостями..."

        try {
            Repair-WinGetPackageManager -AllUsers -ErrorAction Stop | Out-Null
        }
        catch {
            try {
                Repair-WinGetPackageManager -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Log "Метод Microsoft.WinGet.Client не смог установить winget." "WARN"
                return $false
            }
        }

        Start-Sleep -Seconds 5

        if (Test-Winget) {
            Write-Log "winget успешно установлен через Microsoft.WinGet.Client." "SUCCESS"
            return $true
        }

        Write-Log "Microsoft.WinGet.Client завершился, но winget пока не найден." "WARN"
        return $false
    }
    catch {
        Write-Log "Не удалось установить winget через Microsoft.WinGet.Client." "WARN"
        return $false
    }
}

function Install-WingetUsingMsixBundle {
    Write-Log "Пробую установить winget через официальный msixbundle..."

    $wingetBundle = Join-Path $DownloadDir "Microsoft.DesktopAppInstaller.msixbundle"
    $wingetUrl = "https://aka.ms/getwinget"

    try {
        Write-Log "Скачиваю App Installer / winget..."
        Invoke-WebRequest -Uri $wingetUrl -OutFile $wingetBundle -UseBasicParsing -ErrorAction Stop

        if (-not (Test-Path $wingetBundle)) {
            Write-Log "Файл App Installer не был скачан." "WARN"
            return $false
        }

        Write-Log "Устанавливаю App Installer / winget..."

        try {
            Add-AppxPackage -Path $wingetBundle -ErrorAction Stop
        }
        catch {
            Write-Log "Windows не смог установить App Installer. Обычно причина: нет Windows App Runtime или система не обновлена." "WARN"
            Write-Log "Продолжаю без вывода технической ошибки HRESULT." "WARN"
            return $false
        }

        Start-Sleep -Seconds 5

        if (Test-Winget) {
            Write-Log "winget успешно установлен через msixbundle." "SUCCESS"
            return $true
        }

        Write-Log "App Installer установлен, но winget пока не найден." "WARN"
        return $false
    }
    catch {
        Write-Log "Не удалось скачать или установить App Installer." "WARN"
        return $false
    }
}

function Install-WingetIfNeeded {
    if (Test-Winget) {
        Write-Log "winget уже установлен." "SUCCESS"
        return $true
    }

    Write-Log "winget не найден. Начинаю корректную установку зависимостей и winget..." "WARN"

    $resultModule = Install-WingetUsingMicrosoftModule

    if ($resultModule -and (Test-Winget)) {
        return $true
    }

    $resultMsix = Install-WingetUsingMsixBundle

    if ($resultMsix -and (Test-Winget)) {
        return $true
    }

    Write-Log "winget не удалось установить автоматически." "ERROR"
    Write-Log "Причина обычно в том, что Windows слишком свежая/чистая и не имеет нужных компонентов Microsoft Store." "ERROR"
    Write-Log "Решение: запусти Windows Update, обнови Microsoft Store/App Installer и повтори запуск скрипта." "ERROR"

    return $false
}

$WingetReady = Install-WingetIfNeeded

if (-not $WingetReady) {
    Write-Log "Установка программ через winget невозможна. Скрипт продолжит только установку программ из GitHub Release." "WARN"
}
else {
    $Winget = Get-WingetPath
    Write-Log "Путь к winget: $Winget"

    try {
        Write-Log "Обновляю источники winget..."
        & $Winget source update --accept-source-agreements 2>$null | Out-Null
        Write-Log "Источники winget обновлены." "SUCCESS"
    }
    catch {
        Write-Log "Не удалось обновить источники winget. Продолжаю." "WARN"
    }
}

function Test-WingetPackageInstalled {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    if (-not $WingetReady) {
        return $false
    }

    try {
        $output = & $Winget list --id $Id -e --accept-source-agreements 2>$null | Out-String

        if ($output -match [regex]::Escape($Id)) {
            return $true
        }

        return $false
    }
    catch {
        return $false
    }
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    if (-not $WingetReady) {
        Write-Log "Пропускаю $Name, потому что winget недоступен." "WARN"
        return
    }

    Write-Log "Проверяю: $Name [$Id]"

    if (Test-WingetPackageInstalled -Id $Id) {
        Write-Log "Уже установлено: $Name" "SUCCESS"
        return
    }

    Write-Log "Устанавливаю через winget: $Name [$Id]"

    $args = @(
        "install",
        "--id", $Id,
        "-e",
        "--silent",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity"
    )

    try {
        & $Winget @args

        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Log "Успешно установлено: $Name" "SUCCESS"
        }
        else {
            Write-Log "Не удалось установить $Name через winget. Код: $exitCode" "WARN"
        }
    }
    catch {
        Write-Log "Ошибка установки ${Name}. Продолжаю установку остальных программ." "WARN"
    }
}

$WingetApps = @(
    @{
        Name = "Adobe Acrobat Reader / PDF Reader"
        Id   = "Adobe.Acrobat.Reader.64-bit"
    },
    @{
        Name = "Microsoft Office 365"
        Id   = "Microsoft.Office"
    },
    @{
        Name = "KeePassXC"
        Id   = "KeePassXCTeam.KeePassXC"
    },
    @{
        Name = "Freelens"
        Id   = "Freelensapp.Freelens"
    },
    @{
        Name = "Slack"
        Id   = "SlackTechnologies.Slack"
    },
    @{
        Name = "Docker Desktop"
        Id   = "Docker.DockerDesktop"
    },
    @{
        Name = "Postman"
        Id   = "Postman.Postman"
    },
    @{
        Name = "Telegram Desktop"
        Id   = "Telegram.TelegramDesktop"
    },
    @{
        Name = "OpenVPN Connect"
        Id   = "OpenVPNTechnologies.OpenVPNConnect"
    }
)

foreach ($app in $WingetApps) {
    Install-WingetPackage -Name $app.Name -Id $app.Id
}

function Get-GitHubReleaseAssets {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    $apiUrl = "https://api.github.com/repos/$Owner/$Repo/releases/tags/$Tag"

    try {
        Write-Log "Получаю список файлов GitHub Release..."
        $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop
        return $release.assets
    }
    catch {
        Write-Log "Не удалось получить GitHub Release. Проверь repo/tag/интернет." "WARN"
        return @()
    }
}

function Install-ExeFromGitHubRelease {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [Parameter(Mandatory = $true)]
        [string[]]$NamePatterns,

        [string[]]$SilentArgumentsList = @(
            "/quiet /norestart",
            "/S",
            "/silent",
            "/verysilent /norestart"
        )
    )

    Write-Log "Ищу установщик в GitHub Release для: $DisplayName"

    $assets = Get-GitHubReleaseAssets -Owner $GitHubOwner -Repo $GitHubRepo -Tag $GitHubTag

    if (-not $assets -or $assets.Count -eq 0) {
        Write-Log "Нет доступных файлов GitHub Release для $DisplayName." "WARN"
        return
    }

    $matchedAsset = $null

    foreach ($pattern in $NamePatterns) {
        $matchedAsset = $assets | Where-Object {
            $_.name -match $pattern -and $_.name -match '\.exe$'
        } | Select-Object -First 1

        if ($matchedAsset) {
            break
        }
    }

    if (-not $matchedAsset) {
        Write-Log "Не найден .exe файл для $DisplayName в GitHub Release." "WARN"
        return
    }

    $fileName = $matchedAsset.name
    $downloadUrl = $matchedAsset.browser_download_url
    $localFile = Join-Path $DownloadDir $fileName

    try {
        Write-Log "Скачиваю ${DisplayName}: $fileName"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $localFile -UseBasicParsing -ErrorAction Stop

        if (-not (Test-Path $localFile)) {
            Write-Log "Файл не скачался: $localFile" "WARN"
            return
        }

        Write-Log "Файл скачан: $localFile"

        foreach ($silentArgs in $SilentArgumentsList) {
            Write-Log "Пробую тихую установку $DisplayName с аргументами: $silentArgs"

            try {
                $process = Start-Process -FilePath $localFile -ArgumentList $silentArgs -Wait -PassThru -ErrorAction Stop

                if ($process.ExitCode -eq 0) {
                    Write-Log "Успешно установлено: $DisplayName" "SUCCESS"
                    return
                }
                else {
                    Write-Log "$DisplayName не установился с этими аргументами. Код: $($process.ExitCode)" "WARN"
                }
            }
            catch {
                Write-Log "Эта попытка тихой установки $DisplayName не сработала. Пробую следующий вариант." "WARN"
            }
        }

        Write-Log "$DisplayName скачан, но тихо не установился. Возможно, установщик требует ручной запуск." "WARN"
        Write-Log "Файл для ручной установки: $localFile" "WARN"
    }
    catch {
        Write-Log "Не удалось скачать или установить ${DisplayName}." "WARN"
    }
}

if (-not $SkipFortiVPN) {
    Install-ExeFromGitHubRelease `
        -DisplayName "FortiVPN / FortiClient VPN" `
        -NamePatterns @(
            "Forti.*Client.*Installer",
            "Forti.*VPN",
            "FortiClient"
        ) `
        -SilentArgumentsList @(
            "/quiet /norestart",
            "/passive /norestart",
            "/S"
        )
}
else {
    Write-Log "FortiVPN пропущен." "WARN"
}

if (-not $SkipYandexTelemost) {
    Install-ExeFromGitHubRelease `
        -DisplayName "Яндекс Телемост" `
        -NamePatterns @(
            "Telemost",
            "Телемост",
            "Yandex.*Telemost",
            "Yandex.*Meet"
        ) `
        -SilentArgumentsList @(
            "/S",
            "/quiet /norestart",
            "/silent",
            "/verysilent /norestart"
        )
}
else {
    Write-Log "Яндекс Телемост пропущен." "WARN"
}

Write-Log "Финальная проверка программ winget..."

if ($WingetReady) {
    foreach ($app in $WingetApps) {
        if (Test-WingetPackageInstalled -Id $app.Id) {
            Write-Log "OK: $($app.Name)" "SUCCESS"
        }
        else {
            Write-Log "Не подтверждено через winget: $($app.Name)" "WARN"
        }
    }
}
else {
    Write-Log "Финальная проверка winget-программ пропущена, потому что winget недоступен." "WARN"
}

Write-Log "Работа скрипта завершена." "SUCCESS"
Write-Log "Лог находится здесь: $LogFile"


exit 0
