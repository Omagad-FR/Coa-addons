# CoA Addons — installeur
# Telecharge les addons Conquest of Azeroth (Auctionator fork, CoABuffManager,
# DPSLogger, EasyLoot) et les installe dans le client Ascension detecte sur ce
# poste. La base de prix d'hotel des ventes (AuctionatorCoA.lua) est un choix
# separe : par defaut elle n'est jamais touchee.
#
# Usage (fichier local) :
#   powershell -ExecutionPolicy Bypass -File install.ps1              # addons seulement
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Scan        # addons + ecrase le scan existant
#   powershell -ExecutionPolicy Bypass -File install.ps1 -ScanOnly    # scan seulement, n'ecrase pas les addons
#
# Usage (sans telecharger le fichier a la main) :
#   powershell -ExecutionPolicy Bypass -Command "iwr https://raw.githubusercontent.com/Omagad-FR/Coa-addons/main/install.ps1 -useb | iex"
#   powershell -ExecutionPolicy Bypass -Command "&([scriptblock]::Create((iwr https://raw.githubusercontent.com/Omagad-FR/Coa-addons/main/install.ps1 -useb).Content)) -Scan"

param(
    [switch]$Scan,      # ecrase aussi AuctionatorCoA.lua meme s'il existe deja
    [switch]$ScanOnly   # n'installe pas les addons, ecrase seulement le scan
)

$ErrorActionPreference = "Stop"
$RepoZipUrl = "https://github.com/Omagad-FR/Coa-addons/archive/refs/heads/main.zip"
$InstallAddons = -not $ScanOnly
$OverwriteScan = $Scan -or $ScanOnly

function Write-Log($msg) {
    Write-Host "[coa-addons] $msg"
}

# --------------------------------------------------------------- detection jeu

$SkipNames = @(
    "windows","$recycle.bin","system volume information","programdata","appdata",
    "onedrive","node_modules",".git","perflogs","recovery","msocache","intel","nvidia",
    "documents and settings","config.msi","windows.old","packages","temp","tmp"
)

function Test-LooksLikeGame($path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) { return $false }
    return (Test-Path (Join-Path $path "WTF")) -and (
        (Test-Path (Join-Path $path "Interfaces")) -or (Test-Path (Join-Path $path "Interface"))
    )
}

function Get-CandidateGamePaths {
    @(
        "C:\Ascension\Launcher\resources\ascension-live",
        "C:\Ascension\ascension-live",
        "C:\Ascension",
        "C:\Program Files (x86)\Ascension\ascension-live",
        "D:\Ascension\Launcher\resources\ascension-live",
        "D:\Ascension\ascension-live"
    )
}

# Parcours en largeur, profondeur bornee : une install de jeu se trouve
# presque toujours a moins de 4 niveaux d'une racine de disque.
function Find-GameByScan {
    $maxDepth = 4
    $budget = 9000
    $visited = 0
    $queue = New-Object System.Collections.Generic.Queue[object]

    Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match "^[A-Za-z]:\\$" } | ForEach-Object {
        $queue.Enqueue(@{ Path = $_.Root; Depth = 0 })
    }

    Write-Log "Scan des disques en cours, ca peut prendre une minute..."

    while ($queue.Count -gt 0 -and $visited -lt $budget) {
        $current = $queue.Dequeue()
        $visited++

        if ($current.Depth -gt 0 -and (Test-LooksLikeGame $current.Path)) {
            Write-Log "Jeu trouve : $($current.Path) ($visited dossiers parcourus)."
            return $current.Path
        }

        if ($current.Depth -ge $maxDepth) { continue }
        try {
            Get-ChildItem -LiteralPath $current.Path -Directory -Force -ErrorAction Stop | ForEach-Object {
                if ($SkipNames -notcontains $_.Name.ToLower()) {
                    $queue.Enqueue(@{ Path = $_.FullName; Depth = $current.Depth + 1 })
                }
            }
        } catch { }
    }

    return $null
}

function Find-Game {
    foreach ($candidate in (Get-CandidateGamePaths)) {
        if (Test-LooksLikeGame $candidate) { return $candidate }
    }
    $scanned = Find-GameByScan
    if ($scanned) { return $scanned }
    return $null
}

function Get-AddonsFolder($game) {
    $a = Join-Path $game "Interfaces\Addons"
    if (Test-Path $a) { return $a }
    $b = Join-Path $game "Interface\AddOns"
    if (Test-Path $b) { return $b }
    # Aucun des deux n'existe encore : on cree le chemin standard.
    $c = Join-Path $game "Interface\AddOns"
    New-Item -ItemType Directory -Force -Path $c | Out-Null
    return $c
}

function Get-Account($game) {
    $accountsDir = Join-Path $game "WTF\Account"
    if (-not (Test-Path $accountsDir)) { return $null }
    $names = Get-ChildItem -LiteralPath $accountsDir -Directory |
        Where-Object { $_.Name.ToUpper() -ne "SAVEDVARIABLES" } |
        ForEach-Object { $_.Name }
    if (-not $names) { return $null }
    if ($names.Count -eq 1) { return $names[0] }

    Write-Host ""
    Write-Host "Plusieurs comptes trouves :"
    for ($i = 0; $i -lt $names.Count; $i++) { Write-Host "  [$i] $($names[$i])" }
    $choice = Read-Host "Quel compte utiliser (numero, defaut 0)"
    if ([string]::IsNullOrWhiteSpace($choice)) { return $names[0] }
    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 0 -and $idx -lt $names.Count) {
        return $names[$idx]
    }
    return $names[0]
}

# --------------------------------------------------------------- installation

Write-Log "Recherche du client Ascension sur ce poste..."
$game = Find-Game
if (-not $game) {
    Write-Host ""
    $game = Read-Host "Client introuvable automatiquement. Colle le chemin du dossier du jeu (celui avec WTF et Interfaces)"
    if (-not (Test-LooksLikeGame $game)) {
        Write-Log "ERREUR : ce dossier ne ressemble pas a une installation du jeu. Abandon."
        exit 1
    }
}
Write-Log "Jeu : $game"

$account = Get-Account $game
if (-not $account) {
    Write-Log "Aucun compte trouve dans WTF\Account. Connecte-toi au moins une fois au jeu avant d'installer les addons."
    exit 1
}
Write-Log "Compte : $account"

$addonsDest = Get-AddonsFolder $game
Write-Log "Dossier addons : $addonsDest"

$savedVarsDest = Join-Path $game "WTF\Account\$account\SavedVariables"
New-Item -ItemType Directory -Force -Path $savedVarsDest | Out-Null

# --- telechargement

$work = Join-Path $env:TEMP ("coa-addons-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$zipPath = Join-Path $work "coa-addons.zip"

Write-Log "Telechargement depuis GitHub..."
Invoke-WebRequest -Uri $RepoZipUrl -OutFile $zipPath -UseBasicParsing
Expand-Archive -LiteralPath $zipPath -DestinationPath $work -Force

$extracted = Get-ChildItem -LiteralPath $work -Directory | Where-Object { $_.Name -like "coa-addons-*" } | Select-Object -First 1
if (-not $extracted) {
    Write-Log "ERREUR : archive inattendue, abandon."
    exit 1
}

# --- copie des addons

if ($InstallAddons) {
    $sourceAddons = Join-Path $extracted.FullName "Addons"
    Get-ChildItem -LiteralPath $sourceAddons -Directory | ForEach-Object {
        $target = Join-Path $addonsDest $_.Name
        if (Test-Path $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse
        Write-Log "Addon installe (ecrase) : $($_.Name)"
    }
} else {
    Write-Log "Addons non touches (-ScanOnly)."
}

# --- copie de la base de prix. Par defaut : jamais touchee si elle existe deja.
# -Scan ou -ScanOnly force l'ecrasement (avec sauvegarde .bak de l'ancienne).

$sourceSaved = Join-Path $extracted.FullName "SavedVariables\AuctionatorCoA.lua"
$targetSaved = Join-Path $savedVarsDest "AuctionatorCoA.lua"
if (Test-Path $sourceSaved) {
    if (-not (Test-Path $targetSaved)) {
        Copy-Item -LiteralPath $sourceSaved -Destination $targetSaved
        Write-Log "Base de prix d'hotel des ventes installee (premier scan pret a l'emploi)."
    } elseif ($OverwriteScan) {
        $backup = "$targetSaved.bak"
        Copy-Item -LiteralPath $targetSaved -Destination $backup -Force
        Copy-Item -LiteralPath $sourceSaved -Destination $targetSaved -Force
        Write-Log "AuctionatorCoA.lua ecrase (ancien scan sauvegarde dans $backup)."
    } else {
        Write-Log "AuctionatorCoA.lua existe deja pour ce compte : conserve. Relance avec -Scan pour l'ecraser."
    }
}

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Log "Termine. Relance le jeu (ou /reload en jeu) pour charger les addons."
