# CoA Addons

Addons pour le serveur privé [Ascension](https://ascension.gg) — Conquest of Azeroth.

- **AuctionatorCoA** (+ Price Database + Pricing History) — fork Auctionator, avec une base de prix d'hôtel des ventes déjà remplie
- **CoABuffManager** — buffs, overview et synchronisation du groupe
- **DPSLogger** — télémétrie de combat
- **EasyLoot** — gestion du loot simplifiée

## Installation (Windows)

Le script cherche automatiquement ton installation Ascension (chemins
courants, puis scan des disques si besoin). Deux commandes séparées, à coller
dans PowerShell :

**Installer / mettre à jour les addons** (écrase les addons existants, ne
touche jamais à ton scan d'hôtel des ventes) :

```powershell
powershell -ExecutionPolicy Bypass -Command "iwr https://raw.githubusercontent.com/Omagad-FR/Coa-addons/main/install.ps1 -useb | iex"
```

**Installer / écraser la base de prix d'hôtel des ventes** (le full scan
`AuctionatorCoA_Price_Database.lua` — ne touche pas aux addons, sauvegarde
l'ancien scan en `.bak` avant d'écraser) :

```powershell
powershell -ExecutionPolicy Bypass -Command "&([scriptblock]::Create((iwr https://raw.githubusercontent.com/Omagad-FR/Coa-addons/main/install.ps1 -useb).Content)) -ScanOnly"
```

Les deux d'un coup (`-Scan` avec la première commande) :

```powershell
powershell -ExecutionPolicy Bypass -Command "&([scriptblock]::Create((iwr https://raw.githubusercontent.com/Omagad-FR/Coa-addons/main/install.ps1 -useb).Content)) -Scan"
```

Relance le jeu ou fais `/reload` ensuite.

### Installation manuelle

Si tu préfères : télécharge le zip via **Code → Download ZIP** sur cette
page, puis copie le contenu de `Addons/` dans le dossier `Interface/AddOns`
de ton installation Ascension.
