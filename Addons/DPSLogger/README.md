# DPSLogger 2.3

DPSLogger produit des faits de combat bruts destinés à CoASim. Il ne décide
pas lui-même qu'un talent fonctionne d'une certaine manière : il enregistre
les événements permettant au parseur de le démontrer.

## Puissance d'attaque par coup (2.3.0, schéma 3)

Chaque événement de dégâts infligé par le joueur (`SWING_DAMAGE`,
`*_DAMAGE`, `ENVIRONMENTAL_DAMAGE` avec source possédée) porte désormais
`attackPowerAtHit` et `rangedAttackPowerAtHit` : la puissance d'attaque
active au moment du coup, pas seulement au démarrage/arrêt de session ou
lors du dernier `STATS_CHANGED`. La valeur vient d'un cache mis à jour sur
l'événement `UNIT_ATTACK_POWER` (rafraîchi immédiatement, pas au rythme du
sondage de 0,05 s), donc gratuite à lire à chaque coup. Objectif : calibrer
des coefficients d'AP (Pestilence of Death, Burning Blade/Hellburn...) sans
reconstruire l'état d'AP après coup via les auras. Ne couvre que l'AP du
joueur, pas celle d'un pet propriétaire d'un coup.

## HUD in-game (`/coahud`)

Panneau déplaçable qui pilote `/dpslog` sans avoir à taper les commandes :
statut EN MARCHE/ARRETE en direct, navigation dans une liste de tests
(génériques pour toutes les classes, plus une liste Burning
Blade/Domination/Hellborn pour Knight of Xoroth War), boutons
**Commencer ce test** / **Arrêter** / **Marquer**. Il ne fait qu'appeler
le même point d'entrée que les commandes texte : la capture elle-même n'est
pas modifiée. La checklist détaillée et l'archivage des campagnes restent
dans `Tests-Ingame.html` ; le HUD sert à ne pas avoir à alt-tab pendant le
combat. Pour Knight of Xoroth / War, le HUD reprend maintenant les 25 tests
de la campagne complète : Burning Blade, Domination, Demon's Blood,
Brimstone, Hellborn, Pestilences, Rage et combats de référence.

Les sessions 2.2 enregistrent explicitement la classe et la spécialisation,
les identifiants des auras ainsi que des candidats de causalité pour tous les
dégâts, casts et gains de ressources récents. Ces informations permettent au
gestionnaire de relier les variations hors cast, notamment la Rage des coups
blancs et des dégâts reçus.

## Priorités de rotation (`/coaprio`)

Panneau séparé pour classer ses sorts connus par ordre de priorité, en
mono-cible et en zone (AoE) séparément. Les sorts proposés viennent d'un
scan du grimoire du joueur (sorts passifs et non appris exclus) ; le
classement se fait avec les boutons Monter/Descendre/Retirer plutôt que du
glisser-déposer pixel par pixel. Une case de commentaire à droite de chaque
sort classé permet d'expliquer en une ligne pourquoi il est à cette place
("burst d'ouverture", "à garder pour le finisher", etc.). Le résultat est
enregistré dans la SavedVariable `DPSLoggerPriorityDB`, indépendante des
sessions de combat, pour import ultérieur par Addons Data Manager.

La checklist interactive appartient au projet CoA complet. Elle se trouve dans
`../Projets/Conquest-of-Azeroth/Checklists/Tests-Ingame.html`.

Une campagne terminée doit être archivée en JSON dans
`../Projets/Conquest-of-Azeroth/Checklists/Archives` afin que Codex puisse la
relire et que les validations restent disponibles plusieurs mois plus tard.

## Installation

Copier le dossier `DPSLogger` dans `Interface/AddOns`, puis redémarrer WoW ou
utiliser `/reload`.

## Session normale

1. `/dpslog start nom-du-test`
2. Effectuer le combat.
3. Ajouter au besoin un repère avec `/dpslog mark texte`.
4. `/dpslog stop`
5. Utiliser `/reload` ou se déconnecter pour écrire les SavedVariables.

La limite de sécurité est de 60 000 événements par session. Elle peut être
changée avec `/dpslog maxevents 100000`.

## Test Burning Blade / Domination

Pour distinguer consommation des charges et réduction du cooldown :

1. Se placer sur un mannequin, sans autre joueur.
2. Lancer `/dpslog start burning-blade-auto`.
3. Activer Burning Blade et ne faire que des attaques automatiques pendant
   environ 30 secondes.
4. Lancer `/dpslog mark fin-auto`.
5. Utiliser ensuite uniquement une compétence de mêlée identifiable pendant
   environ 30 secondes.
6. Lancer `/dpslog stop`, puis `/dpslog check`.

Le rapport sépare :

- `AURA_CHANGED` avec une baisse des charges de Burning Blade ;
- `COOLDOWN_REDUCED` avec la baisse mesurée du délai ;
- les critiques candidats survenus dans les 350 ms précédentes ;
- attaque automatique, compétence de mêlée ou cause indéterminée.

Pour vérifier visuellement le compteur à tout moment :

`/dpslog cooldown`

## Commandes

- `/dpslog start [nom]`
- `/dpslog stop`
- `/dpslog status`
- `/dpslog mark texte`
- `/dpslog cooldown`
- `/dpslog check`
- `/dpslog watch Nom du sort`
- `/dpslog last`
- `/dpslog count`
- `/dpslog maxevents N`
- `/dpslog clear confirm`
- `/coahud` — afficher/masquer le HUD de pilotage
- `/coaprio` — afficher/masquer le panneau de priorités de rotation
