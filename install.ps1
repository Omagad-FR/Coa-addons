# CoA Addons — installeur
# Telecharge les addons Conquest of Azeroth et les installe dans le client
# Ascension detecte sur ce poste. Pose la question a l'ecran si aucune option
# n'est donnee : tous les addons, certains seulement, ou juste la base de
# prix d'hotel des ventes (le "full scan" Auctionator).
#
# Usage interactif (recommande) :
#   powershell -ExecutionPolicy Bypass -Command "iwr https://raw.githubusercontent.com/Omagad-FR/Coa-addons/main/install.ps1 -useb | iex"
#
# Usage silencieux (pas de question posee) :
#   ... -File install.ps1 -All                    # tous les addons + le scan
#   ... -File install.ps1 -AddonsAll               # tous les addons, pas le scan
#   ... -File install.ps1 -ScanOnly                # juste le scan
#   ... -File install.ps1 -Addon AuctionatorCoA,EasyLoot   # addons choisis, pas le scan

param(
    [switch]$All,           # tout : addons + scan, sans poser de question
    [switch]$AddonsAll,     # tous les addons seulement, sans poser de question
    [switch]$ScanOnly,      # scan seulement, sans poser de question
    [string[]]$Addon        # liste d'addons precise, sans poser de question
)

$ErrorActionPreference = "Stop"
$RepoZipUrl = "https://github.com/Omagad-FR/Coa-addons/archive/refs/heads/main.zip"
$ScanFileName = "AuctionatorCoA_Price_Database.lua"

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
    # @(...) force le tableau : avec un seul compte trouve, le pipeline renvoie
    # une chaine nue et $names[0] indexerait alors son premier CARACTERE, pas
    # le nom entier (bug reel constate : compte "teisserenc" -> dossier "T").
    $names = @(Get-ChildItem -LiteralPath $accountsDir -Directory |
        Where-Object { $_.Name.ToUpper() -ne "SAVEDVARIABLES" } |
        ForEach-Object { $_.Name })
    if (-not $names -or $names.Count -eq 0) { return $null }
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

# --- telechargement (toujours necessaire : la liste d'addons pour le menu
# vient de l'archive elle-meme, pas d'une liste codee en dur)

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

$sourceAddonsRoot = Join-Path $extracted.FullName "Addons"
# @(...) meme raison que Get-Account : ne jamais laisser un resultat unique
# s'aplatir en chaine nue.
$availableAddons = @(Get-ChildItem -LiteralPath $sourceAddonsRoot -Directory | ForEach-Object { $_.Name })

# --------------------------------------------------------------- choix de l'action

$selectedAddons = @()
$overwriteScan = $false

$noninteractiveFlagGiven = $All -or $AddonsAll -or $ScanOnly -or ($Addon -and $Addon.Count -gt 0)

if ($noninteractiveFlagGiven) {
    if ($All)        { $selectedAddons = $availableAddons; $overwriteScan = $true }
    if ($AddonsAll)   { $selectedAddons = $availableAddons }
    if ($ScanOnly)    { $overwriteScan = $true }
    if ($Addon)       { $selectedAddons = $Addon }
} else {
    Write-Host ""
    Write-Host "Que veux-tu faire ?"
    Write-Host "  [1] Installer tous les addons"
    Write-Host "  [2] Installer certains addons seulement"
    Write-Host "  [3] Mettre a jour seulement la base de prix (scan Auctionator)"
    Write-Host "  [4] Tout : tous les addons + la base de prix"
    $choice = Read-Host "Choix (1-4)"

    switch ($choice) {
        "2" {
            Write-Host ""
            Write-Host "Addons disponibles :"
            for ($i = 0; $i -lt $availableAddons.Count; $i++) { Write-Host "  [$i] $($availableAddons[$i])" }
            $picked = Read-Host "Numeros separes par une virgule (ex: 0,2)"
            $indexes = $picked -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
            foreach ($ix in $indexes) {
                $n = 0
                if ([int]::TryParse($ix, [ref]$n) -and $n -ge 0 -and $n -lt $availableAddons.Count) {
                    $selectedAddons += $availableAddons[$n]
                }
            }
        }
        "3" { $overwriteScan = $true }
        "4" { $selectedAddons = $availableAddons; $overwriteScan = $true }
        default { $selectedAddons = $availableAddons }  # "1" ou entree vide : tous les addons
    }
}

# --- copie des addons choisis

foreach ($name in $selectedAddons) {
    $source = Join-Path $sourceAddonsRoot $name
    if (-not (Test-Path $source)) {
        Write-Log "Addon inconnu, ignore : $name"
        continue
    }
    $target = Join-Path $addonsDest $name
    if (Test-Path $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    Copy-Item -LiteralPath $source -Destination $target -Recurse
    Write-Log "Addon installe (ecrase) : $name"
}
if ($selectedAddons.Count -eq 0) {
    Write-Log "Aucun addon a installer."
}

# --- copie de la base de prix. Le vrai fichier de scan est
# AuctionatorCoA_Price_Database.lua (variable AUCTIONATOR_PRICE_DATABASE,
# declaree dans AuctionatorCoA_Price_Database.toc) — PAS AuctionatorCoA.lua,
# qui ne contient que les reglages perso (AUCTIONATOR_SAVEDVARS).
# Le fichier existant n'est jamais ecrase sans que ce soit demande.

$sourceSaved = Join-Path $extracted.FullName "SavedVariables\$ScanFileName"
$targetSaved = Join-Path $savedVarsDest $ScanFileName
if (Test-Path $sourceSaved) {
    if (-not (Test-Path $targetSaved)) {
        Copy-Item -LiteralPath $sourceSaved -Destination $targetSaved
        Write-Log "Base de prix d'hotel des ventes installee (premier scan pret a l'emploi)."
    } elseif ($overwriteScan) {
        $backup = "$targetSaved.bak"
        Copy-Item -LiteralPath $targetSaved -Destination $backup -Force
        Copy-Item -LiteralPath $sourceSaved -Destination $targetSaved -Force
        Write-Log "$ScanFileName ecrase (ancien scan sauvegarde dans $backup)."
    } else {
        Write-Log "$ScanFileName existe deja pour ce compte : conserve."
    }
} elseif ($overwriteScan) {
    Write-Log "ERREUR : $ScanFileName absent de l'archive telechargee."
}

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Log "Termine. Relance le jeu (ou /reload en jeu) pour charger les addons."
