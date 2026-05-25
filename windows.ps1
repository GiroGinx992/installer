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
    Write-Log "Скрипт должен быть запущен от имени администратора." "ERROR"
    Write-Log "Открой PowerShell от имени администратора и запусти команду ещё раз." "ERROR"
    exit 1
}

Write-Log "Скрипт запущен от имени администратора." "SUCCESS"
Write-Log "Лог файл: $LogFile"


try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Log "TLS 1.2 включён."
}
catch {
    Write-Log "Не удалось включить TLS 1.2: $($_.Exception.Message)" "WARN"
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

    $windowsAppsPath = Join-Path $env:ProgramFiles "WindowsApps"

    if (Test-Path $windowsAppsPath) {
        $found = Get-ChildItem -Path $windowsAppsPath -Filter "winget.exe" -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($found) {
            return $found.FullName
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
        & $wingetPath --version | Out-Null
        return $true
    }
    catch {
        return $false
    }
}



function Install-Winget {
    Write-Log "winget не найден. Начинаю установку App Installer / winget..." "WARN"

    $wingetBundle = Join-Path $DownloadDir "Microsoft.DesktopAppInstaller.msixbundle"
    $wingetUrl = "https://aka.ms/getwinget"

    try {
        Write-Log "Скачиваю winget: $wingetUrl"
        Invoke-WebRequest -Uri $wingetUrl -OutFile $wingetBundle -UseBasicParsing

        if (-not (Test-Path $wingetBundle)) {
            Write-Log "Файл winget не скачался: $wingetBundle" "ERROR"
            return $false
        }

        Write-Log "Устанавливаю App Installer / winget..."
        Add-AppxPackage -Path $wingetBundle -ErrorAction Stop

        Start-Sleep -Seconds 5

        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path", "User")

        if (Test-Winget) {
            Write-Log "winget успешно установлен." "SUCCESS"
            return $true
        }

        Write-Log "winget установлен, но пока не найден в PATH. Возможно, нужен перезапуск PowerShell или Windows." "WARN"
        return $false
    }
    catch {
        Write-Log "Ошибка установки winget: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

if (-not (Test-Winget)) {
    $installedWinget = Install-Winget

    if (-not $installedWinget) {
        Write-Log "Не удалось автоматически установить winget." "ERROR"
        Write-Log "Проверь App Installer / Microsoft Store / Windows Update и запусти скрипт повторно." "ERROR"
        exit 1
    }
}
else {
    Write-Log "winget найден." "SUCCESS"
}

$Winget = Get-WingetPath
Write-Log "Путь к winget: $Winget"



function Initialize-Winget {
    try {
        Write-Log "Обновляю источники winget..."
        & $Winget source update --accept-source-agreements | Out-Null

        Write-Log "Проверяю источники winget..."
        $sources = & $Winget source list 2>$null | Out-String

        foreach ($line in $sources -split "`n") {
            if ($line.Trim()) {
                Write-Log $line.Trim()
            }
        }

        Write-Log "winget готов к работе." "SUCCESS"
    }
    catch {
        Write-Log "Ошибка инициализации winget: $($_.Exception.Message)" "WARN"
    }
}

Initialize-Winget



function Test-WingetPackageInstalled {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

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
            Write-Log "winget вернул код $exitCode для $Name" "WARN"
        }
    }
    catch {
        Write-Log "Ошибка установки ${Name}: $($_.Exception.Message)" "ERROR"
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
        Write-Log "Получаю список файлов GitHub Release: $apiUrl"
        $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing
        return $release.assets
    }
    catch {
        Write-Log "Не удалось получить GitHub Release: $($_.Exception.Message)" "ERROR"
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
        Write-Log "Нет файлов в GitHub Release или не удалось их получить." "WARN"
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
        Invoke-WebRequest -Uri $downloadUrl -OutFile $localFile -UseBasicParsing

        if (-not (Test-Path $localFile)) {
            Write-Log "Файл не скачался: $localFile" "ERROR"
            return
        }

        Write-Log "Файл скачан: $localFile"

        foreach ($silentArgs in $SilentArgumentsList) {
            Write-Log "Пробую тихую установку $DisplayName с аргументами: $silentArgs"

            try {
                $process = Start-Process -FilePath $localFile -ArgumentList $silentArgs -Wait -PassThru

                if ($process.ExitCode -eq 0) {
                    Write-Log "Успешно установлено: $DisplayName" "SUCCESS"
                    return
                }
                else {
                    Write-Log "$DisplayName вернул код: $($process.ExitCode)" "WARN"
                }
            }
            catch {
                Write-Log "Попытка установки не удалась: $($_.Exception.Message)" "WARN"
            }
        }

        Write-Log "Не удалось тихо установить $DisplayName. Возможно, установщик требует ручного режима." "WARN"
    }
    catch {
        Write-Log "Ошибка установки ${DisplayName} из GitHub Release: $($_.Exception.Message)" "ERROR"
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
    Write-Log "FortiVPN пропущен параметром -SkipFortiVPN" "WARN"
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
    Write-Log "Яндекс Телемост пропущен параметром -SkipYandexTelemost" "WARN"
}



Write-Log "Проверяю установленные приложения через winget..."

foreach ($app in $WingetApps) {
    if (Test-WingetPackageInstalled -Id $app.Id) {
        Write-Log "OK: $($app.Name)" "SUCCESS"
    }
    else {
        Write-Log "Не подтверждено через winget: $($app.Name)" "WARN"
    }
}

Write-Log "Установка завершена." "SUCCESS"
Write-Log "Лог находится здесь: $LogFile"
Write-Log "ВАЖНО: после установки Docker Desktop, Office или VPN-клиентов может потребоваться перезагрузка Windows." "WARN"

exit 0
