#requires -version 5.1


$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$LogDir  = "C:\Temp\OnboardingInstall"
$LogFile = Join-Path $LogDir "install-log.txt"



$InstallDockerDesktop = $true

# FortiClient VPN fallback.

$FortiClientVpnInstaller = "C:\Installers\FortiClientVPNOnlineInstaller.exe"
$FortiClientVpnInstallerArgs = "/quiet /norestart"

# Яндекс Телемост fallback.
$YandexTelemostInstaller = "\\server\soft\YandexTelemost\YandexTelemostSetup.exe"
$YandexTelemostInstallerArgs = "/silent"

# Возможные winget ID.
$YandexTelemostWingetIds = @(
    "Yandex.Telemost",
    "Yandex.YandexTelemost"
)

$FortiClientVpnWingetIds = @(
    "Fortinet.FortiClientVPN"
)


if (!(Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)

    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "[$Time] $Message"
    Write-Host $Line
    Add-Content -Path $LogFile -Value $Line -Encoding UTF8
}

function Test-Admin {
    $CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($CurrentUser)

    if (!$Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "ОШИБКА: PowerShell нужно запустить от имени администратора."
        exit 1
    }

    Write-Log "Проверка администратора: OK"
}

function Add-WingetPath {
    $PossiblePaths = @(
        "$env:LOCALAPPDATA\Microsoft\WindowsApps",
        "C:\Program Files\WindowsApps"
    )

    foreach ($PathItem in $PossiblePaths) {
        if ((Test-Path $PathItem) -and ($env:Path -notlike "*$PathItem*")) {
            $env:Path += ";$PathItem"
        }
    }
}

function Get-WingetCommand {
    Add-WingetPath
    return Get-Command winget -ErrorAction SilentlyContinue
}

function Test-WingetReady {
    $WingetCommand = Get-WingetCommand

    if (!$WingetCommand) {
        return $false
    }

    try {
        $Version = & winget --version 2>$null
        if ($LASTEXITCODE -eq 0 -and $Version) {
            Write-Log "winget найден: $($WingetCommand.Source), версия: $Version"
            return $true
        }
    } catch {
        Write-Log "winget найден, но не запускается: $($_.Exception.Message)"
    }

    return $false
}

function Repair-ExistingAppInstaller {
    Write-Log "Пробую восстановить уже установленный Microsoft.DesktopAppInstaller."

    try {
        $Packages = Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue

        if (!$Packages) {
            Write-Log "Microsoft.DesktopAppInstaller не найден среди установленных Appx-пакетов."
            return $false
        }

        foreach ($Package in $Packages) {
            $Manifest = Join-Path $Package.InstallLocation "AppxManifest.xml"

            if (Test-Path $Manifest) {
                Write-Log "Регистрирую App Installer заново: $Manifest"
                Add-AppxPackage -DisableDevelopmentMode -Register $Manifest -ErrorAction Stop
            }
        }

        Start-Sleep -Seconds 5
        return (Test-WingetReady)
    } catch {
        Write-Log "Не удалось восстановить App Installer через AppxManifest: $($_.Exception.Message)"
        return $false
    }
}

function Install-WingetWithPowerShellModule {
    Write-Log "Пробую установить/починить winget через модуль Microsoft.WinGet.Client."

    try {
        if (!(Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Write-Log "Устанавливаю NuGet provider для PowerShellGet."
            Install-PackageProvider -Name NuGet -Force -Scope AllUsers -ErrorAction Stop | Out-Null
        }

        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue

        if (!(Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
            Write-Log "Устанавливаю PowerShell-модуль Microsoft.WinGet.Client."
            Install-Module -Name Microsoft.WinGet.Client -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
        }

        Import-Module Microsoft.WinGet.Client -Force -ErrorAction Stop

        if (Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue) {
            Write-Log "Запускаю Repair-WinGetPackageManager -AllUsers -Force."
            Repair-WinGetPackageManager -AllUsers -Force -Latest -ErrorAction Stop
            Start-Sleep -Seconds 10
            return (Test-WingetReady)
        }

        Write-Log "Команда Repair-WinGetPackageManager недоступна в установленном модуле."
        return $false
    } catch {
        Write-Log "Не удалось установить winget через Microsoft.WinGet.Client: $($_.Exception.Message)"
        return $false
    }
}

function Install-WingetWithMsixBundle {
    Write-Log "Пробую установить winget через официальный msixbundle."

    $TempDir = Join-Path $env:TEMP "winget-bootstrap"
    $WingetBundle = Join-Path $TempDir "Microsoft.DesktopAppInstaller.msixbundle"
    $VCLibs = Join-Path $TempDir "Microsoft.VCLibs.x64.14.00.Desktop.appx"

    try {
        if (!(Test-Path $TempDir)) {
            New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
        }

        Write-Log "Скачиваю Microsoft VCLibs dependency."
        Invoke-WebRequest -Uri "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx" -OutFile $VCLibs -UseBasicParsing -ErrorAction Stop

        Write-Log "Скачиваю App Installer / winget bundle."
        Invoke-WebRequest -Uri "https://aka.ms/getwinget" -OutFile $WingetBundle -UseBasicParsing -ErrorAction Stop

        Write-Log "Устанавливаю Microsoft VCLibs."
        Add-AppxPackage -Path $VCLibs -ErrorAction SilentlyContinue

        Write-Log "Устанавливаю Microsoft Desktop App Installer."
        Add-AppxPackage -Path $WingetBundle -ErrorAction Stop

        Start-Sleep -Seconds 10
        return (Test-WingetReady)
    } catch {
        Write-Log "Не удалось установить winget через msixbundle: $($_.Exception.Message)"
        return $false
    }
}

function Ensure-Winget {
    Write-Log "Проверяю наличие winget."

    if (Test-WingetReady) {
        return
    }

    Write-Log "winget не найден или не запускается. Начинаю автоматическое восстановление/установку."

    if (Repair-ExistingAppInstaller) {
        Write-Log "winget успешно восстановлен через существующий App Installer."
        return
    }

    if (Install-WingetWithPowerShellModule) {
        Write-Log "winget успешно установлен через Microsoft.WinGet.Client."
        return
    }

    if (Install-WingetWithMsixBundle) {
        Write-Log "winget успешно установлен через msixbundle."
        return
    }

    Write-Log "ОШИБКА: winget не удалось установить автоматически."
    Write-Log "Проверь интернет, Microsoft Store/App Installer, PowerShellGet и политику выполнения Appx-пакетов."
    Write-Log "После ручной установки App Installer запусти этот скрипт повторно."
    exit 1
}

function Initialize-WingetSources {
    Write-Log "Инициализирую источники winget."

    try {
        winget source reset --force --accept-source-agreements | Out-Null
        winget source update --accept-source-agreements | Out-Null
        Write-Log "Источники winget готовы."
    } catch {
        Write-Log "Не удалось обновить источники winget: $($_.Exception.Message)"
    }
}

function Install-WingetApp {
    param(
        [string]$Name,
        [string]$Id,
        [string]$Scope = "machine"
    )

    Write-Log "Проверяю: $Name [$Id]"

    try {
        $Installed = winget list --id $Id -e --accept-source-agreements 2>$null

        if ($LASTEXITCODE -eq 0 -and $Installed -match [regex]::Escape($Id)) {
            Write-Log "Уже установлено: $Name"
            return $true
        }
    } catch {
        Write-Log "Не удалось проверить наличие $Name через winget list: $($_.Exception.Message)"
    }

    Write-Log "Устанавливаю через winget: $Name [$Id]"

    $Args = @(
        "install",
        "--id", $Id,
        "-e",
        "--silent",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity"
    )

    if ($Scope -eq "machine") {
        $Args += @("--scope", "machine")
    }

    try {
        & winget @Args
        $Code = $LASTEXITCODE

        if ($Code -eq 0) {
            Write-Log "УСПЕШНО: $Name"
            return $true
        }

        Write-Log "ОШИБКА установки через winget: $Name. Код: $Code"
        return $false
    } catch {
        Write-Log "Исключение при установке $Name через winget: $($_.Exception.Message)"
        return $false
    }
}

function Install-FromInstaller {
    param(
        [string]$Name,
        [string]$InstallerPath,
        [string]$Arguments
    )

    if (!(Test-Path $InstallerPath)) {
        Write-Log "$Name пропущен. Установщик не найден: $InstallerPath"
        return $false
    }

    Write-Log "Устанавливаю $Name из установщика: $InstallerPath"

    try {
        $Process = Start-Process -FilePath $InstallerPath -ArgumentList $Arguments -Wait -PassThru

        if ($Process.ExitCode -eq 0) {
            Write-Log "УСПЕШНО: $Name"
            return $true
        }

        Write-Log "Установка $Name завершилась с кодом: $($Process.ExitCode)"
        return $false
    } catch {
        Write-Log "Ошибка запуска установщика ${Name}: $($_.Exception.Message)"
        return $false
    }
}

function Install-FortiClientVpn {
    Write-Log "Проверяю/устанавливаю FortiClient VPN."

    foreach ($WingetId in $FortiClientVpnWingetIds) {
        $Result = Install-WingetApp -Name "FortiClient VPN" -Id $WingetId -Scope "machine"

        if ($Result -eq $true) {
            Write-Log "FortiClient VPN установлен или уже был установлен через winget."
            return
        }
    }

    Write-Log "FortiClient VPN через winget установить не удалось. Пробую fallback-установщик."
    $FallbackResult = Install-FromInstaller -Name "FortiClient VPN" -InstallerPath $FortiClientVpnInstaller -Arguments $FortiClientVpnInstallerArgs

    if ($FallbackResult -ne $true) {
        Write-Log "ВНИМАНИЕ: FortiClient VPN не установлен."
        Write-Log "Решение: скачай официальный FortiClient VPN installer и укажи путь в переменной `$FortiClientVpnInstaller."
    }
}

function Install-YandexTelemost {
    Write-Log "Проверяю/устанавливаю Яндекс Телемост."

    foreach ($WingetId in $YandexTelemostWingetIds) {
        $Result = Install-WingetApp -Name "Яндекс Телемост" -Id $WingetId -Scope "machine"

        if ($Result -eq $true) {
            Write-Log "Яндекс Телемост установлен или уже был установлен через winget."
            return
        }
    }

    Write-Log "Через winget Яндекс Телемост установить не удалось. Проверяю fallback-установщик."
    $FallbackResult = Install-FromInstaller -Name "Яндекс Телемост" -InstallerPath $YandexTelemostInstaller -Arguments $YandexTelemostInstallerArgs

    if ($FallbackResult -ne $true) {
        Write-Log "ВНИМАНИЕ: Яндекс Телемост не установлен."
        Write-Log "Решение: скачай официальный установщик и укажи путь в переменной `$YandexTelemostInstaller."
    }
}


Test-Admin

Write-Log "=========================================="
Write-Log "Старт установки onboarding ПО для Windows"
Write-Log "Лог: $LogFile"
Write-Log "=========================================="

Ensure-Winget
Initialize-WingetSources

$Apps = @(
    @{
        Name  = "Adobe Acrobat Reader"
        Id    = "Adobe.Acrobat.Reader.64-bit"
        Scope = "machine"
    },
    @{
        Name  = "Microsoft 365 Apps / Office"
        Id    = "Microsoft.Office"
        Scope = "none"
    },
    @{
        Name  = "KeePassXC"
        Id    = "KeePassXCTeam.KeePassXC"
        Scope = "machine"
    },
    @{
        Name  = "Freelens"
        Id    = "Freelensapp.Freelens"
        Scope = "machine"
    },
    @{
        Name  = "Slack"
        Id    = "SlackTechnologies.Slack"
        Scope = "machine"
    },
    @{
        Name  = "Postman"
        Id    = "Postman.Postman"
        Scope = "user"
    },
    @{
        Name  = "Telegram Desktop"
        Id    = "Telegram.TelegramDesktop"
        Scope = "machine"
    },
    @{
        Name  = "OpenVPN Connect"
        Id    = "OpenVPNTechnologies.OpenVPNConnect"
        Scope = "machine"
    }
)

foreach ($App in $Apps) {
    Install-WingetApp -Name $App.Name -Id $App.Id -Scope $App.Scope
}

if ($InstallDockerDesktop) {
    Install-WingetApp -Name "Docker Desktop" -Id "Docker.DockerDesktop" -Scope "machine"
} else {
    Write-Log "Docker Desktop пропущен. Нужно подтвердить лицензию Docker для вашей организации."
}

Install-FortiClientVpn
Install-YandexTelemost

Write-Log "Установка завершена"
Write-Log "Лог: $LogFile"


exit 0
