# StackPilot - SSH Configurator (Windows PowerShell)
# Konfiguruje połączenie SSH do serwera Mikrus (klucz + alias).
# Author: Paweł (Lazy Engineer)
#
# Użycie:
#   iwr -useb https://raw.githubusercontent.com/jurczykpawel/stackpilot/main/local/setup-ssh.ps1 | iex

Clear-Host
Write-Host "=================================================" -ForegroundColor Blue
Write-Host "   MIKRUS SSH CONFIGURATOR - WINDOWS             " -ForegroundColor Blue
Write-Host "=================================================" -ForegroundColor Blue
Write-Host ""
Write-Host "Ten skrypt skonfiguruje Twoje polaczenie z Mikrusem tak,"
Write-Host -NoNewline "abys mogl laczyc sie wpisujac tylko: "
Write-Host "ssh mikrus" -ForegroundColor Green
Write-Host "(bez wpisywania hasla za kazdym razem!)"
Write-Host ""
Write-Host "Przygotuj dane z maila od Mikrusa (Host, Port, Haslo)." -ForegroundColor Yellow
Write-Host ""

# --- Sprawdzenie i automatyczna instalacja OpenSSH ---
$sshPath = Get-Command ssh -ErrorAction SilentlyContinue
if (-not $sshPath) {
    Write-Host "Nie znaleziono klienta SSH. Instaluje automatycznie..." -ForegroundColor Yellow

    # Sprawdzenie czy jestesmy adminem
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Host "Potrzebne sa uprawnienia administratora do instalacji OpenSSH." -ForegroundColor Yellow
        Write-Host "Otwieram okno z uprawnieniami..." -ForegroundColor Yellow

        # Zapisz skrypt do pliku tymczasowego i uruchom jako admin
        $tempScript = Join-Path $env:TEMP "install_openssh.ps1"
        @'
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
'@ | Set-Content $tempScript

        Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$tempScript`"" -Wait
        Remove-Item $tempScript -ErrorAction SilentlyContinue

        # Odswiezenie PATH po instalacji
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    } else {
        Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
    }

    # Sprawdz ponownie
    $sshPath = Get-Command ssh -ErrorAction SilentlyContinue
    if (-not $sshPath) {
        Write-Host "BLAD: Nie udalo sie zainstalowac OpenSSH!" -ForegroundColor Red
        Write-Host "Sprobuj recznie: Ustawienia -> Aplikacje -> Funkcje opcjonalne -> OpenSSH Client" -ForegroundColor Yellow
        return
    }
    Write-Host "OpenSSH zainstalowany pomyslnie!" -ForegroundColor Green
    Write-Host ""
}

# --- Pobieranie danych ---
$Host_ = Read-Host "Podaj nazwe hosta (np. srv20.mikr.us)"
$Port = Read-Host "Podaj numer portu (np. 10107)"
$User = Read-Host "Podaj nazwe uzytkownika (domyslnie: root)"
if ([string]::IsNullOrWhiteSpace($User)) { $User = "root" }
$Alias = Read-Host "Jak chcesz nazwac ten serwer w terminalu? (domyslnie: mikrus)"
if ([string]::IsNullOrWhiteSpace($Alias)) { $Alias = "mikrus" }

if ([string]::IsNullOrWhiteSpace($Host_) -or [string]::IsNullOrWhiteSpace($Port)) {
    Write-Host "BLAD: Host i Port sa wymagane!" -ForegroundColor Red
    return
}

Write-Host ""
Write-Host "Sprawdzam klucze SSH..." -ForegroundColor Blue

# --- Przygotowanie folderu .ssh ---
$sshDir = Join-Path $env:USERPROFILE ".ssh"
if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
}

# --- Generowanie klucza SSH ---
$keyPath = Join-Path $sshDir "id_ed25519"
if (-not (Test-Path $keyPath)) {
    Write-Host "Nie znaleziono klucza SSH. Generuje nowy bezpieczny klucz (Ed25519)..." -ForegroundColor Yellow
    Write-Host ""
    $keyPass = Read-Host "Podaj haslo dla klucza SSH (lub Enter dla bez hasla)"
    if ([string]::IsNullOrWhiteSpace($keyPass)) {
        ssh-keygen -t ed25519 -f $keyPath -N '""' -C "mikrus_$($env:COMPUTERNAME)"
    } else {
        ssh-keygen -t ed25519 -f $keyPath -N $keyPass -C "mikrus_$($env:COMPUTERNAME)"
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "BLAD: Nie udalo sie wygenerowac klucza SSH!" -ForegroundColor Red
        return
    }
    Write-Host "Klucz wygenerowany pomyslnie." -ForegroundColor Green
} else {
    Write-Host "Znaleziono istniejacy klucz SSH." -ForegroundColor Green
}

# --- Kopiowanie klucza na serwer ---
$pubKeyPath = "$keyPath.pub"
$pubKey = Get-Content $pubKeyPath -Raw

Write-Host ""
Write-Host "=================================================" -ForegroundColor Blue
Write-Host "TERAZ WAZNE:" -ForegroundColor Yellow -NoNewline
Write-Host " Za chwile zostaniesz poproszony o wpisanie hasla do Mikrusa."
Write-Host "To JEDYNY raz, kiedy bedziesz musial je wpisac."
Write-Host "=================================================" -ForegroundColor Blue
Write-Host ""
Read-Host "Nacisnij Enter, aby kontynuowac"

# Windows nie ma ssh-copy-id, robimy to recznie
$pubKeyTrimmed = $pubKey.Trim()
$remoteCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pubKeyTrimmed' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
ssh -p $Port "$User@$Host_" $remoteCmd

if ($LASTEXITCODE -ne 0) {
    Write-Host "Wystapil blad podczas wysylania klucza. Sprawdz haslo i sprobuj ponownie." -ForegroundColor Red
    return
}

Write-Host "Klucz zostal skopiowany na serwer." -ForegroundColor Green

# --- Konfiguracja ~/.ssh/config ---
$configFile = Join-Path $sshDir "config"
if (-not (Test-Path $configFile)) {
    New-Item -ItemType File -Path $configFile -Force | Out-Null
}

$configContent = Get-Content $configFile -Raw -ErrorAction SilentlyContinue
if ($configContent -and $configContent -match "Host\s+$Alias(\s|$)") {
    Write-Host "Alias '$Alias' juz istnieje w pliku config. Pomijam dodawanie." -ForegroundColor Yellow
} else {
    $entry = @"

Host $Alias
    HostName $Host_
    Port $Port
    User $User
    IdentityFile $keyPath
    ServerAliveInterval 60
"@
    Add-Content -Path $configFile -Value $entry
    Write-Host "Dodano konfiguracje do $configFile" -ForegroundColor Green
}

Write-Host ""
Write-Host "=================================================" -ForegroundColor Blue
Write-Host "   SUKCES! KONFIGURACJA ZAKONCZONA!              " -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Blue
Write-Host ""
Write-Host "Od teraz mozesz polaczyc sie ze swoim serwerem wpisujac:"
Write-Host ""
Write-Host "   ssh $Alias" -ForegroundColor Green
Write-Host ""
Write-Host "Sprobuj to teraz!"
