

$ErrorActionPreference = "Continue"



$LogDir = "C:\Temp\OnboardingInstall"
$LogFile = "$LogDir\install-log.txt"

# Docker Desktop:
$InstallDockerDesktop = $true

# Яндекс Телемост:

# $YandexTelemostInstaller = "\\server\soft\YandexTelemost\YandexTelemostSetup.exe"
# $YandexTelemostInstaller = "C:\Installers\YandexTelemostSetup.exe"
$YandexTelemostInstaller = "\\server\soft\YandexTelemost\YandexTelemostSetup.exe"

# Возможные winget ID для Яндекс Телемост могут отличаться.
# Скрипт сначала попробует найти/установить по этим ID.
$YandexTelemostWingetIds = @(
    "Yandex.Telemost",
    "Yandex.YandexTelemost"
)



if (!(Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param(
        [string]$Message
    )

    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "[$Time] $Message"

    Write-Host $Line
    Add-Content -Path $LogFile -Value $Line
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

function Test-Winget {
    $WingetCommand = Get-Command winget -ErrorAction SilentlyContinue

    if (!$WingetCommand) {
        $WingetPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"

        if (Test-Path $WingetPath) {
            $env:Path += ";$env:LOCALAPPDATA\Microsoft\WindowsApps"
            $WingetCommand = Get-Command winget -ErrorAction SilentlyContinue
        }
    }

    if (!$WingetCommand) {
        Write-Log "ОШИБКА: winget не найден."
        Write-Log "Установи или обнови App Installer из Microsoft Store."
        Write-Log "Проверка App Installer: Get-AppxPackage Microsoft.DesktopAppInstaller"
        exit 1
    }

    Write-Log "winget найден: $($WingetCommand.Source)"
}

function Install-WingetApp {
    param(
        [string]$Name,
        [string]$Id,
        [string]$Scope = "machine"
    )

    Write-Log "Проверяю: $Name [$Id]"

    $Installed = winget list --id $Id -e --accept-source-agreements 2>$null

    if ($LASTEXITCODE -eq 0 -and $Installed -match [regex]::Escape($Id)) {
        Write-Log "Уже установлено: $Name"
        return $true
    }

    Write-Log "Устанавливаю лицензионное ПО из winget: $Name [$Id]"

    if ($Scope -eq "user") {
        winget install `
            --id $Id `
            -e `
            --silent `
            --accept-package-agreements `
            --accept-source-agreements
    }
    elseif ($Scope -eq "none") {
        winget install `
            --id $Id `
            -e `
            --silent `
            --accept-package-agreements `
            --accept-source-agreements
    }
    else {
        winget install `
            --id $Id `
            -e `
            --silent `
            --accept-package-agreements `
            --accept-source-agreements `
            --scope machine
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Log "УСПЕШНО: $Name"
        return $true
    } else {
        Write-Log "ОШИБКА установки: $Name. Код: $LASTEXITCODE"
        return $false
    }
}

function Install-YandexTelemost {
    Write-Log "Проверяю: Яндекс Телемост"

    foreach ($WingetId in $YandexTelemostWingetIds) {
        Write-Log "Пробую установить Яндекс Телемост через winget ID: $WingetId"

        $Result = Install-WingetApp `
            -Name "Яндекс Телемост" `
            -Id $WingetId `
            -Scope "machine"

        if ($Result -eq $true) {
            Write-Log "Яндекс Телемост установлен или уже был установлен через winget."
            return
        }
    }

    Write-Log "Через winget Яндекс Телемост установить не удалось. Проверяю локальный установщик."

    if (!(Test-Path $YandexTelemostInstaller)) {
        Write-Log "Яндекс Телемост пропущен. Не найден официальный установщик: $YandexTelemostInstaller"
        Write-Log "Скачай официальный установщик Яндекс Телемост и укажи путь в переменной `$YandexTelemostInstaller."
        return
    }

    Write-Log "Устанавливаю Яндекс Телемост из локального установщика: $YandexTelemostInstaller"

    $Process = Start-Process `
        -FilePath $YandexTelemostInstaller `
        -ArgumentList "/silent" `
        -Wait `
        -PassThru

    if ($Process.ExitCode -eq 0) {
        Write-Log "УСПЕШНО: Яндекс Телемост"
    } else {
        Write-Log "Установка Яндекс Телемост завершилась с кодом: $($Process.ExitCode)"
    }
}



Test-Admin
Test-Winget

Write-Log "=========================================="
Write-Log "Старт установки onboarding ПО для Windows"
Write-Log "=========================================="


# УСТАНОВКА ЧЕРЕЗ WINGET


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
    Install-WingetApp `
        -Name $App.Name `
        -Id $App.Id `
        -Scope $App.Scope
}



if ($InstallDockerDesktop) {
    Install-WingetApp `
        -Name "Docker Desktop" `
        -Id "Docker.DockerDesktop" `
        -Scope "machine"
} else {
    Write-Log "Docker Desktop пропущен. Нужно подтвердить лицензию Docker для вашей организации."
}



Install-YandexTelemost


Write-Log "Установка завершена"
Write-Log "Лог: $LogFile"


exit 0
