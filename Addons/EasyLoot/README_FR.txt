EasyLoot 0.5.3
==============

made by Omagad

Addon WoW 3.3.5a (Interface 30300, WoW Classic) pour distribuer les pieces
d'equipement en raid : scan des sacs, verrous, annonce en alerte plein
ecran, depouillement des jets. Generique : ne depend d'aucun serveur ni
projet en particulier.

Installation
------------

Copier le dossier EasyLoot dans Interface\AddOns\, puis /reload.
Commande : /easyloot (ou /elraid). Une icone pres de la minimap ouvre/ferme
aussi le panneau (clic gauche) et se deplace a la souris (glisser). Pour la
masquer : /easyloot minimap off.


Utilisation
-----------

1. "Scanner les sacs" : liste uniquement les pieces equipables epiques
   (violettes) presentes dans les sacs. Le compte rendu affiche
   aussi ce qui a ete ecarte et pourquoi, pour qu'une piece absente de la
   liste ne ressemble pas a un bug.

   Le butin de raid arrive LIE des le ramassage tout en restant echangeable
   quelques heures : ces pieces sont donc bien listees, marquees en vert
   "echangeable", et remontees en tete de liste puisque ce sont elles qui
   ont une date limite. "lie" en gris signale au contraire une piece dont
   la fenetre d'echange est passee ou absente.
2. Clic gauche sur une ligne : selectionne la piece a annoncer.
   Clic droit  : verrouille / deverrouille. Une piece verrouillee est grisee
                 et ne peut pas etre annoncee (protection de ton propre
                 stuff). Les verrous sont conserves entre les sessions.
   Maj + clic  : insere le lien de l'objet dans la barre de chat.
3. "Annoncer en alerte raid" : affiche la piece au milieu de l'ecran de tout
   le raid, exactement comme /rw, et ouvre une fenetre de jets de 30 s.
4. Le raid repond avec un /roll ordinaire. Les jets sont captes, tries, et le
   panneau du bas affiche les 5 meilleurs, le gagnant, ou une egalite.
5. "Cloturer les jets" ferme la fenetre avant la fin du delai.
   "Annoncer le gagnant" envoie le resultat en alerte raid.
6. Le champ "Destinataire" se pre-remplit avec le gagnant du jet, et un clic
   sur n'importe quelle ligne de jet le remplit aussi avec ce joueur (evite
   de retaper un nom, sujet aux fautes de frappe et aux suffixes de
   royaume) -- modifiable si le gagnant ne vient pas, ou pour une decision
   manuelle du ML :
   "Preparer l'echange" arme le placement automatique -- des que TU ouvres
   une fenetre d'echange avec ce joueur, la piece y est deposee toute seule,
   plus besoin de la chercher dans les sacs. L'echange reste a valider
   normalement des deux cotes.
   "Confirmer distribution" enregistre tout de suite la piece dans
   l'historique (echange deja fait a la main, ou attribution sans jet).
   Un echange automatique confirme en jeu (message "Trade complete.")
   s'enregistre aussi tout seul dans l'historique.
7. "Historique" (en haut a droite) ouvre une fenetre separee qui liste QUI A
   REELLEMENT RECU chaque piece, la plus recente en tete, avec la methode
   (echange confirme ou assignation manuelle). C'est la seule source fiable
   pour repondre a "qui a deja loot" : le gagnant d'un jet n'y figure que
   s'il a effectivement recupere la piece.

Aucun message n'est envoye sans un clic. L'addon ne lance aucun sort et ne
detruit aucun objet ; le seul geste automatique est de deposer la piece
attendue dans une fenetre d'echange DEJA ouverte par toi avec le bon
destinataire (voir "Preparer l'echange" et /easyloot autotrade).


Comment l'annonce est envoyee
-----------------------------

/rw est l'avertissement raid : il affiche un texte au milieu de l'ecran, il
ne lance aucun jet. L'addon utilise directement le canal RAID_WARNING
(SendChatMessage), qui est le meme mecanisme sans dependre de la barre de
chat ni du nom exact de l'alias.

L'avertissement raid est reserve au chef de raid et aux assistants. Sans ce
rang, le panneau l'indique en haut et l'annonce retombe automatiquement sur
le canal du raid plutot que d'etre perdue.

Trois modes existent (/easyloot mode) :
  alerte  message plein ecran, canal RAID_WARNING   (defaut, equivaut a /rw)
  raid    message ordinaire dans le canal du raid
  slash   ecrit litteralement la commande dans la barre de chat et l'envoie,
          repli utile seulement si le serveur ajoute un comportement propre
          a sa commande


Sources de jets
---------------

- CHAT_MSG_SYSTEM : les /roll standards, source principale. Le format est lu
  dans la globale RANDOM_ROLL_RESULT, donc independant de la langue du
  client, avec un motif de repli generique.
- Canaux raid / groupe, en appoint : pour un joueur qui ecrit son chiffre au
  lieu de lancer /roll. Seules les formes non ambigues sont acceptees ("85",
  "roll 85"), et cette source peut etre coupee (rollsFromChat).

Un seul jet est retenu par joueur, le premier. En cas d'egalite, le panneau
et le message de resultat listent les ex aequo et demandent une relance.

Si un jet n'est pas capte, faire /easyloot debug puis relancer une annonce :
chaque message recu pendant la fenetre est alors affiche en clair dans le
chat, ce qui permet d'ajouter le motif manquant dans EasyLoot_Rolls.lua.


Commandes
---------

/easyloot                 ouvre ou ferme le panneau
/easyloot scan            relance le scan des sacs
/easyloot texte <txt>     modele du message, %s = la piece
/easyloot mode alerte|raid|slash   comment l'annonce est envoyee
/easyloot cmd <txt>       commande utilisee par le mode slash (defaut "/rw %s")
/easyloot lien on|off     annoncer le lien cliquable        (defaut on)
/easyloot duree <s>       duree de la fenetre de jets       (defaut 30)
/easyloot qualite         rappelle que le filtre est fixe sur epique (qualite 4)
/easyloot lies on|off     afficher les objets lies dont la fenetre d'echange
                         est passee                        (defaut off)
/easyloot echange <txt>   phrase de repli de la fenetre d'echange
/easyloot verrous         vide tous les verrous
/easyloot autotrade on|off  placer la piece automatiquement des l'echange
                         (defaut on)
/easyloot historique      affiche les 10 dernieres distributions dans le chat
/easyloot historique reset  vide l'historique et les badges (entre 2 soirees)
/easyloot minimap on|off  afficher l'icone pres de la minimap  (defaut on)
/easyloot debug           affiche les messages bruts pendant les jets


Qui a reellement recu chaque piece
-----------------------------------

Le gagnant d'un jet n'est qu'une designation : rien ne garantit qu'il vient
recuperer sa piece. EasyLoot ne considere une piece comme distribuee que
lorsque le ML le confirme, de deux facons possibles :

- Automatique : "Preparer l'echange" arme l'attente. Des que le ML ouvre une
  fenetre d'echange avec le joueur attendu (nom court, sans le royaume),
  EasyLoot y depose la piece toute seule (elle est retiree des sacs pour
  etre placee dans la case d'echange -- l'echange en lui-meme reste a
  valider normalement par les deux joueurs). Quand le client confirme
  l'echange ("Trade complete."), l'entree est enregistree dans l'historique
  avec la methode "echange".
- Manuel : "Confirmer distribution" enregistre immediatement le nom saisi
  dans le champ Destinataire, sans attendre d'echange -- utile si la piece a
  deja ete donnee a la main, ou pour une decision du ML sans jet.

Dans les deux cas, l'entree part dans un historique persistant (bouton
"Historique", ou /easyloot historique), qui liste piece, destinataire,
methode et heure, le plus recent en tete. C'est la reference pour "qui a
deja loot", separee de la simple annonce d'un gagnant de jet.

Le placement automatique manipule un objet des sacs (le sort de
PickupContainerItem vers la fenetre d'echange) : desactivable par
/easyloot autotrade off si le ML echange autre chose en meme temps que la
distribution du loot.


Badge de double loot (sur plusieurs boss)
------------------------------------------

Chaque ligne de jet affiche un badge : quel serait le Nieme loot du joueur
s'il gagne cette piece, calcule sur TOUT l'historique -- donc valable sur
plusieurs boss dans la meme soiree, pas seulement le boss courant.

  +1  vert    jamais loot depuis le dernier "Vider"
  +2  orange  a deja recu une piece
  +3+ rouge   a deja recu deux pieces ou plus

Legende rappelee en bas du panneau de jets. Le gagnant affiche aussi son
badge.

Persistance : l'historique est dans EasyLootDB (SavedVariables), donc il
SURVIT au /reload et aux changements de zone -- c'est voulu, pour couvrir
toute une soiree de raid sur plusieurs boss sans rien perdre.

Reset : JAMAIS automatique. L'addon ne devine pas qu'une nouvelle soiree de
raid commence. A vider a la main entre deux soirees :
/easyloot historique reset, ou bouton "Vider" dans la fenetre Historique
(demande confirmation). Oublier de vider fait remonter les badges d'une
soiree precedente.


Limites connues
---------------

- Les verrous sont indexes par identifiant d'objet et suffixe aleatoire :
  deux exemplaires strictement identiques dans les sacs partagent donc le
  meme verrou.
- Un objet absent du cache du client n'apparait pas au premier scan. Le
  nombre d'objets concernes est signale, il suffit de rescanner.
- Seuls les sacs sont lus, pas la banque ni le butin du groupe.
- La detection de la fenetre d'echange utilise la globale
  BIND_TRADE_TIME_REMAINING quand le client l'expose. Sinon elle retombe sur
  une recherche de texte dans l'infobulle, dependante de la langue du
  serveur et modifiable par /easyloot echange. Le temps restant n'est pas
  extrait, seulement la presence de la fenetre.
- L'addon ne finalise aucun echange : il peut deposer la piece dans la
  fenetre d'echange deja ouverte, mais valider l'echange reste un geste
  manuel des deux cotes, comme toujours en jeu.
- Le placement automatique compare des noms courts (sans royaume) : deux
  joueurs de meme nom sur des royaumes differents dans le meme groupe
  entrent en conflit (cas rare en raid).
- L'historique est local a la machine du ML (SavedVariables EasyLootDB),
  comme tout le reste de l'addon ; il n'est pas partage avec le reste du
  raid.
