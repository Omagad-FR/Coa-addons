# CoA Addons

Addons pour le serveur privé [Ascension](https://ascension.gg) — Conquest of Azeroth.

- **AuctionatorCoA** (+ Price Database + Pricing History) — fork Auctionator, avec une base de prix d'hôtel des ventes déjà remplie
- **CoABuffManager** — buffs, overview et synchronisation du groupe
- **DPSLogger** — télémétrie de combat
- **EasyLoot** — gestion du loot simplifiée

## Installation (Windows)

Le script cherche automatiquement ton installation Ascension (chemins
courants, puis scan des disques si besoin), puis pose la question à
l'écran. Une seule commande à coller dans PowerShell :

```powershell
powershell -ExecutionPolicy Bypass -Command "iwr https://raw.githubusercontent.com/Omagad-FR/Coa-addons/main/install.ps1 -useb | iex"
```

Il demande ensuite :

```
Que veux-tu faire ?
  [1] Installer tous les addons
  [2] Installer certains addons seulement
  [3] Mettre a jour seulement la base de prix (scan Auctionator)
  [4] Tout : tous les addons + la base de prix
```

Le scan (`AuctionatorCoA_Price_Database.lua`) n'écrase jamais un scan
existant sauf si tu choisis explicitement l'option 3 ou 4 — et une sauvegarde
`.bak` de l'ancien est gardée.

### Usage silencieux (scripts, sans question posée)

```powershell
... -File install.ps1 -All                              # tout
... -File install.ps1 -AddonsAll                         # tous les addons, pas le scan
... -File install.ps1 -ScanOnly                          # scan seulement
... -File install.ps1 -Addon AuctionatorCoA,EasyLoot      # addons choisis
```

Relance le jeu ou fais `/reload` ensuite.

### Installation manuelle

Si tu préfères : télécharge le zip via **Code → Download ZIP** sur cette
page, puis copie le contenu de `Addons/` dans le dossier `Interface/AddOns`
de ton installation Ascension.
