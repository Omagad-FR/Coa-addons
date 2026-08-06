# CoA Addons

Addons pour le serveur privé [Ascension](https://ascension.gg) — Conquest of Azeroth.

- **AuctionatorCoA** (+ Price Database + Pricing History) — fork Auctionator, avec une base de prix d'hôtel des ventes déjà remplie
- **CoABuffManager** — buffs, overview et synchronisation du groupe
- **DPSLogger** — télémétrie de combat
- **EasyLoot** — gestion du loot simplifiée

## Installation (Windows)

Ouvre PowerShell et colle :

```powershell
powershell -ExecutionPolicy Bypass -Command "iwr https://raw.githubusercontent.com/Omagad-FR/coa-addons/main/install.ps1 -useb | iex"
```

Le script :
1. cherche automatiquement ton installation Ascension (chemins courants, puis
   scan des disques si besoin) ;
2. copie les addons dans `Interface/AddOns` ;
3. installe une base de prix de départ pour l'hôtel des ventes — seulement si
   tu n'en as pas déjà une (jamais d'écrasement d'un scan personnel).

Relance le jeu ou fais `/reload` ensuite.

### Installation manuelle

Si tu préfères : télécharge le zip via **Code → Download ZIP** sur cette
page, puis copie le contenu de `Addons/` dans le dossier `Interface/AddOns`
de ton installation Ascension.
