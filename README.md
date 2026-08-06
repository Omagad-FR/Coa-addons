# Omagad Addons

Addons pour le serveur privé [Ascension](https://ascension.gg) — Conquest of Azeroth.

- **AuctionatorCoA** (+ Price Database + Pricing History) — fork Auctionator, avec une base de prix d'hôtel des ventes déjà remplie
- **CoABuffManager** — buffs, overview et synchronisation du groupe
- **DPSLogger** — télémétrie de combat
- **EasyLoot** — gestion du loot simplifiée

## Installation (Windows)

Télécharge **[OmagadAddonsInstaller.exe](https://github.com/Omagad-FR/Coa-addons/raw/main/OmagadAddonsInstaller.exe)**
et lance-le. Pas d'installation, pas de dépendance à installer.

L'appli :
1. cherche automatiquement ton installation Ascension (chemins courants, puis
   scan des disques si besoin — demande le chemin à la main si rien n'est
   trouvé) ;
2. te laisse choisir : tous les addons, certains seulement, et/ou la base de
   prix d'hôtel des ventes ;
3. installe tout ça au bon endroit dans ton dossier `WTF` / `Interface`.

La base de prix n'écrase jamais un scan existant, sauf si tu coches
explicitement la case pour ça (une sauvegarde `.bak` de l'ancien scan est
gardée).

Relance le jeu ou fais `/reload` ensuite.

Windows peut afficher un avertissement SmartScreen (exécutable non signé) —
clique sur *Informations complémentaires → Exécuter quand même*.

### Alternative : script PowerShell

Pour ceux qui préfèrent une ligne de commande plutôt qu'une fenêtre, ou pour
scripter une installation : [`install.ps1`](install.ps1), avec le même menu
en mode texte.

```powershell
powershell -ExecutionPolicy Bypass -Command "iwr https://raw.githubusercontent.com/Omagad-FR/Coa-addons/main/install.ps1 -useb | iex"
```

### Installation manuelle

Télécharge le zip via **Code → Download ZIP** sur cette page, puis copie le
contenu de `Addons/` dans le dossier `Interface/AddOns` de ton installation
Ascension.

## Soutenir le projet

☕ [ko-fi.com/omagad](https://ko-fi.com/omagad) — aussi accessible depuis un
bouton dans l'application.
