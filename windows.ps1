
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

$ErrorActionPreference = "Continue"

$Owner = "GiroGinx992"
$Repo = "installer"

$BaseDir = "$env:ProgramData\OnboardingInstaller"
$DownloadDir = Join-Path $BaseDir "downloads"
$LogDir = Join-Path $BaseDir "logs"
$LogFile = Join-Path $LogDir "install-windows.log"

New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "[$Time] [$Level] $Message"

    Write-Host $Line
    Add-Content -Path $LogFile -Value $Line
}

function Test-Admin {
    $CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($CurrentUser)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-GitHubLatestRelease {
    $Url = "https://api.github.com/repos/$Owner/$Repo/releases/latest"

    $Headers = @{
        "User-Agent" = "OnboardingInstaller-Windows"
        "Accept"     = "application/vnd.github+json"
    }

    for ($i = 1; $i -le 5; $i++) {
        try {
            Write-Log "Получаю GitHub Release. Попытка $i"
            return Invoke-RestMethod -Uri $Url -Headers $Headers -TimeoutSec 60 -ErrorAction Stop
        }
        catch {
            Write-Log "Ошибка получения Release: $($_.Exception.Message)" "WARN"
            Start-Sleep -Seconds 5
        }
    }

    throw "Не удалось получить GitHub Release после 5 попыток."
}

function Get-Asset {
    param(
        [object]$Release,
        [string]$Pattern
    )

    return $Release.assets | Where-Object {
        $_.name -match $Pattern
    } | Select-Object -First 1
}

function Download-Asset {
    param(
        [object]$Asset
    )

    if ($null -eq $Asset) {
        throw "Asset не найден."
    }

    $OutFile = Join-Path $DownloadDir $Asset.name

    if (Test-Path $OutFile) {
        $LocalSize = (Get-Item $OutFile).Length
        if ($LocalSize -eq $Asset.size) {
            Write-Log "Файл уже скачан: $($Asset.name)"
            return $OutFile
        }
    }

    Write-Log "Скачиваю: $($Asset.name)"
    Write-Log "URL: $($Asset.browser_download_url)"

    Invoke-WebRequest `
        -Uri $Asset.browser_download_url `
        -OutFile $OutFile `
        -UseBasicParsing `
        -TimeoutSec 0

    Write-Log "Скачано: $OutFile"
    return $OutFile
}

function Install-MSI {
    param(
        [string]$Path,
        [string]$Name,
        [string]$ExtraArgs = ""
    )

    Write-Log "Устанавливаю MSI: $Name"

    $Args = "/i `"$Path`" /qn /norestart $ExtraArgs"

    $Process = Start-Process `
        -FilePath "msiexec.exe" `
        -ArgumentList $Args `
        -Wait `
        -PassThru

    if ($Process.ExitCode -eq 0 -or $Process.ExitCode -eq 3010) {
        Write-Log "Успешно установлено: $Name. Код: $($Process.ExitCode)"
    }
    else {
        Write-Log "Ошибка установки $Name. Код: $($Process.ExitCode)" "ERROR"
    }
}

function Install-EXE {
    param(
        [string]$Path,
        [string]$Name,
        [string[]]$ArgumentsList
    )

    foreach ($Args in $ArgumentsList) {
        Write-Log "Пробую установить EXE: $Name с аргументами: $Args"

        $Process = Start-Process `
            -FilePath $Path `
            -ArgumentList $Args `
            -Wait `
            -PassThru

        if ($Process.ExitCode -eq 0 -or $Process.ExitCode -eq 3010) {
            Write-Log "Успешно установлено: $Name. Код: $($Process.ExitCode)"
            return
        }
        else {
            Write-Log "Неудачная попытка установки $Name. Код: $($Process.ExitCode)" "WARN"
        }
    }

    Write-Log "Не удалось тихо установить: $Name" "ERROR"
}

function Install-MSIX {
    param(
        [string]$Path,
        [string]$Name
    )

    Write-Log "Устанавливаю MSIX: $Name"

    try {
        Add-AppxPackage -Path $Path -ErrorAction Stop
        Write-Log "Успешно установлено: $Name"
    }
    catch {
        Write-Log "Ошибка установки MSIX $Name: $($_.Exception.Message)" "ERROR"
    }
}

function Install-Office365 {
    param(
        [string]$OfficeSetupPath
    )

    Write-Log "Готовлю установку Microsoft Office 365"

    $OfficeDir = Split-Path $OfficeSetupPath -Parent
    $ConfigPath = Join-Path $OfficeDir "configuration.xml"

    $Config = @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="Current">
    <Product ID="O365ProPlusRetail">
      <Language ID="ru-ru" />
      <Language ID="en-us" />
    </Product>
  </Add>
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="AUTOACTIVATE" Value="1" />
  <Updates Enabled="TRUE" />
</Configuration>
"@

    Set-Content -Path $ConfigPath -Value $Config -Encoding UTF8

    Write-Log "Запускаю OfficeSetup.exe /configure configuration.xml"

    $Process = Start-Process `
        -FilePath $OfficeSetupPath `
        -ArgumentList "/configure `"$ConfigPath`"" `
        -Wait `
        -PassThru

    if ($Process.ExitCode -eq 0 -or $Process.ExitCode -eq 3010) {
        Write-Log "Microsoft Office 365 установлен. Код: $($Process.ExitCode)"
    }
    else {
        Write-Log "Ошибка установки Microsoft Office 365. Код: $($Process.ExitCode)" "ERROR"
    }
}

Write-Log "=== Старт установки onboarding ПО для Windows ==="

if (-not (Test-Admin)) {
    Write-Log "Скрипт нужно запускать от имени администратора." "ERROR"
    exit 1
}

try {
    $Release = Get-GitHubLatestRelease
    Write-Log "Release найден: $($Release.name), Tag: $($Release.tag_name)"
}
catch {
    Write-Log $_ "ERROR"
    exit 1
}

# Docker Desktop
$DockerAsset = Get-Asset $Release "Docker\.Desktop\.Installer\.exe$"
if ($DockerAsset) {
    $DockerPath = Download-Asset $DockerAsset
    Install-EXE $DockerPath "Docker Desktop" @(
        "install --quiet --accept-license",
        "install --quiet",
        "--quiet"
    )
}
else {
    Write-Log "Docker Desktop для Windows не найден в Release" "WARN"
}

# FortiClient VPN
$FortiAsset = Get-Asset $Release "FortiClientInstaller\.exe$"
if ($FortiAsset) {
    $FortiPath = Download-Asset $FortiAsset
    Install-EXE $FortiPath "FortiClient VPN" @(
        "/quiet /norestart",
        "/silent /norestart",
        "/S"
    )
}
else {
    Write-Log "FortiClientInstaller.exe не найден в Release" "WARN"
}

# Freelens
$FreelensAsset = Get-Asset $Release "Freelens-.*windows.*\.exe$"
if ($FreelensAsset) {
    $FreelensPath = Download-Asset $FreelensAsset
    Install-EXE $FreelensPath "Freelens" @(
        "/S",
        "--silent",
        "/quiet"
    )
}
else {
    Write-Log "Freelens для Windows не найден в Release" "WARN"
}

# KeePassXC
$KeePassAsset = Get-Asset $Release "KeePassXC-.*Win64\.msi$"
if ($KeePassAsset) {
    $KeePassPath = Download-Asset $KeePassAsset
    Install-MSI $KeePassPath "KeePassXC"
}
else {
    Write-Log "KeePassXC MSI не найден в Release" "WARN"
}

# Microsoft Office 365
$OfficeAsset = Get-Asset $Release "OfficeSetup\.exe$"
if ($OfficeAsset) {
    $OfficePath = Download-Asset $OfficeAsset
    Install-Office365 $OfficePath
}
else {
    Write-Log "OfficeSetup.exe не найден в Release" "WARN"
}

# OpenVPN
$OpenVPNAsset = Get-Asset $Release "OpenVPN-.*\.msi$"
if ($OpenVPNAsset) {
    $OpenVPNPath = Download-Asset $OpenVPNAsset
    Install-MSI $OpenVPNPath "OpenVPN"
}
else {
    Write-Log "OpenVPN MSI не найден в Release" "WARN"
}

# Postman
$PostmanAsset = Get-Asset $Release "Postman.*\.exe$"
if ($PostmanAsset) {
    $PostmanPath = Download-Asset $PostmanAsset
    Install-EXE $PostmanPath "Postman" @(
        "--silent",
        "/S",
        "/quiet"
    )
}
else {
    Write-Log "Postman для Windows не найден в Release" "WARN"
}

# Slack
$SlackAsset = Get-Asset $Release "Slack\.msix$"
if ($SlackAsset) {
    $SlackPath = Download-Asset $SlackAsset
    Install-MSIX $SlackPath "Slack"
}
else {
    Write-Log "Slack.msix не найден в Release" "WARN"
}

# Яндекс Телемост
$TelemostAsset = Get-Asset $Release "TelemostSetup\.exe$"
if ($TelemostAsset) {
    $TelemostPath = Download-Asset $TelemostAsset
    Install-EXE $TelemostPath "Яндекс Телемост" @(
        "/S",
        "--silent",
        "/quiet"
    )
}
else {
    Write-Log "TelemostSetup.exe не найден в Release" "WARN"
}

Write-Log "=== Установка завершена ==="
Write-Log "Лог: $LogFile"
