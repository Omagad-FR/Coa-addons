CoA Buff Manager 0.23.0
=======================

Version 0.23.0
--------------
- Suppression de la macro "BUFF THEM ALL" et du bouton "Buff" du HUD flottant :
  au-dela de quelques verrous, la sequence /castsequence generee depassait la
  limite de 255 caracteres des macros et s'arretait de se mettre a jour sans
  prevenir. Buffer se fait desormais uniquement via les boutons de l'Overview
  et les lignes du suivi flottant (HUD), sans limite de nombre de verrous.
- Le suivi flottant (HUD) signale maintenant, par ligne verrouillee, si une
  personne visee est morte ou deconnectee (marque orange + details dans
  l'infobulle "Mort/deco, a rebuff : ..."), pour rappeler de la rebuff une
  fois relevee. Ces personnes ne comptent plus comme "buff manquant" tant
  qu'elles sont mortes (on ne peut pas buffer un cadavre).
- Nettoyage Reglages : bouton "Regenerer BUFF THEM ALL" et case "Masquer les
  messages de mise a jour" retires (n'avaient plus d'effet).
- A tester en jeu : verifier que le suivi flottant affiche bien le marqueur
  mort/deco en donjon a 5, et que la fenetre HUD garde une taille/anchor
  coherente sans la bande reservee a l'ancien bouton Buff.

Version 0.22.0
--------------
- Le bouton compact propose maintenant trois modes : masquer les buffs de raid,
  masquer les buffs personnels, ou masquer tous les buffs.
- Les buffs masques sont toujours reaffiches temporairement au survol du bouton.

Version 0.21.2
--------------
- Ajout d'une option dans Reglages pour masquer dans le chat les confirmations
  automatiques de mise a jour de la macro BUFF THEM ALL.
- Les avertissements et erreurs de generation restent toujours visibles.

Installation
------------
1. Fermer le jeu.
2. Copier le dossier CoABuffManager dans Interface\AddOns\.
3. Relancer le jeu et verifier que CoA Buff Manager est active.

Affichage compact des buffs
----------------------------
1. Ouvrir CoA Buff Manager avec /cbm.
2. Cliquer sur Reglages.
3. Cocher "Remplacer la barre de buffs par un bouton".
4. Laisser "Reafficher les buffs au survol" coche pour voir la barre native
   uniquement lorsque la souris passe sur le bouton compact.

Le clic sur le bouton compact permet aussi d'ouvrir ou fermer la barre si le
mode de survol est desactive.

Pour deplacer le bouton, cocher "Deverrouiller le bouton pour le deplacer",
puis le faire glisser avec le clic gauche. Sa position est sauvegardee.

Controle du groupe
------------------
Le nombre rouge correspond maintenant au nombre de joueurs capables de poser
un buff de groupe mais qui n'ont actuellement aucun de leurs buffs actifs.
Un joueur ne compte qu'une seule fois, meme s'il peut choisir entre plusieurs
buffs mutuellement exclusifs. Une variante personnelle active compte egalement
comme son choix (par exemple Mark of Korth'azz au lieu de Greater Mark of
Korth'azz). L'infobulle indique le joueur, sa classe et les choix possibles.

Le controle utilise aussi les classes de tous les membres du groupe. Quand un
membre equipe de CoABuffManager a communique ses sorts connus, ceux-ci sont
confirmes precisement ; sinon la base embarquee propose les possibilites de sa
classe et les marque comme "possible".

La page /cbm > Reglages contient aussi une section "Controle du groupe" avec
la liste des buffs disponibles mais absents. Le bouton "Actualiser le
controle" force une nouvelle verification.

Notes
-----
- Aucun buff n'est lance automatiquement.
- Les membres morts ou deconnectes ne comptent pas comme "buff manquant"
  (impossible de buffer un cadavre) dans le controle du groupe, mais le suivi
  flottant (HUD) les signale separement pour ne pas oublier de les rebuff.
- La barre native n'est ni remplacee ni modifiee : elle est seulement masquee,
  afin de conserver ses infobulles et son comportement habituel au survol.
- L'option est desactivee par defaut lors de la mise a jour.
