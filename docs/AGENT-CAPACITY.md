# Capacité native : 48 zombies ordinaires et réserve pour les spéciaux

## Port direct en cours — 19 octobre 2026

La reprise humaine demande de réaliser directement le port. Le suivi du chemin
après l'initialisation conserve maintenant la page `14B3C5000` sur un dédié
privé restauré : `14B3C5D01` prépare EDX=24 et ECX=66 avant `140AF6310`.
La référence retenue de ce callee publie un autre stockage à `143C986A0`,
avec comptes A8/AC et pas `0xA0`. Son buffer fixe et son remplissage distinct
doivent aussi être dimensionnés ; cette dépendance ne se confond pas avec B8.

Pour relier les consommateurs et poursuivre le port sans un lancement par
fragment, le lecteur prépare une capture opt-in des deux seuls spans exécutables
fixes du PE actuel : `140001000/1427E00` et `14B2B4000/104D400`, soit
38 228 480 octets initiaux et exactement quatre lectures/76 456 960 octets au
maximum. Le handle conserve l'identité image/création et les régions doivent être
engagées/exécutables/lisibles. Chaque page différente est explicitement exclue
des preuves stables ; sa deuxième version est conservée (128 pages maximum par
span) pour reconstruire et contrôler le second hash complet.
Aucune section de données, suspension, écriture cible ou cohérence globale n'est
revendiquée. Les captures restent locales et ignorées. Cinq groupes de tests
passent, dont refus de section arbitraire, données tronquées et sortie existante,
avec qualification séparée des pages modifiées. La première acquisition réelle
a refusé une section non identique ; le capteur natif ferme et le dédié quitte
normalement, restauré/réservation libérée. Ce cas reste échoué. La nouvelle
acquisition a conservé les deux spans et exclu quatre pages différentes :
`14121D000`, `141280000`, `14B770000`, `14C0B0000`. Le manifeste local a le hash
`958AD7FA2EAD7E931CD87656DF40C429995C71DF42D92B15B39DA684C8FD917E`.
La fermeture UDP de ce cas a échoué ; à l'investigation le processus exact était
absent, sans code de sortie connu. La récupération indépendante a préservé le
résultat échoué et le journal, vérifié l'absence du candidat, restauré les deux
transactions et libéré sa réservation. Cela ne prouve pas une sortie normale.

Le candidat privé `paris_agent_capacity` implémente maintenant K=64 : 48 ordinaires
et une réserve provisoire de 16, 82 personnages et début des entités carte à 98.
Il reloge les agents, sentients et tables de travail, agrandit les objets de
personnages serveur/client et les références associées. Les formats et compteurs
existants sont conservés. Les accès à RVA absolue sont distincts des accès RIP.
Les longueurs de sauvegarde des tables 8/20 octets utilisent déjà leurs comptes
dynamiques. Le stockage voisin `145D16710` appartient à un autre objet et reste
intact ; sa proximité n'en fait pas la fin logique de notre nouveau pool.

Le port n'est compilé que dans le profil privé debugger. Il est désactivé sans
`-paris-capacity-64` et exige une identité CP isolée et un port privé explicites.
Les emplacements attendus sont vérifiés avant une transaction d'écriture ; les
buffers restent vivants jusqu'à la fermeture du processus, avec gardes suivies.
La compilation, la création de 64 agents avec client correspondant, les cinq
cartes et les mesures de charge restent à établir. Aucun passage à 48 ni absence
de lag/crash n'est encore validé ou livré sur Main. La règle GSC de 48 ordinaires
doit être qualifiée séparément des 64 places natives.

## Diagnostic actuel qualifié, capacité inchangée — 19 octobre 2026

Le second essai utilise le source `8ef8f1e` et le binaire
`87A9717D2C817369E59BF689B35EB6F98717CA6ABE09E657EEBFA9188B808024`,
compilé le 19 octobre à 14:15:22 UTC. Les deux rôles scheduler valident leurs
canaries ; un unique restart vide produit 18 écritures et l'accusé natif final
confirme zéro erreur, DR/handler fermés. Le reader conserve huit pages stables,
32 KiB de payload, avec 16 lectures/64 KiB et ferme son handle. Le dédié quitte
normalement (code 0), la transaction est restaurée et la réservation libérée.
Ni Main, ni le client habituel ne sont modifiés. Aucun joueur ni scénario de
combat n'est lancé ; ce résultat n'est pas une mesure de performance à 48.

Le journal original SHA256 est
`307CBAC33E6644B9F36DE034085243643C7DD01BBB1898E78E86922E9038FE85` ;
le résultat `A067434052EEF03B63E9A9182B1548576C4A09571ACFCFCB58DFB615750ED4C8` ;
le manifeste des pages `9853FF03AE3D7D00A0FA2750D8DABA6CB5FA0DE25F5565034C762F53045B5409`.
Les bytes et contextes restent locaux, ignorés. Le premier essai échoué reste
conservé séparément ; son succès de restauration ne devient pas un succès natif.

La lecture bornée des nouvelles pages retrouve les deux sites candidats de
publication et ferme le backedge statique d'initialisation : la taille de
remplissage est `0x78180`, le pas `0x5010`, et la comparaison de boucle est
`0x78180`, soit 24 records. `14B5383F9` recharge le pointeur B8 et reconduit le
chemin vers `140B20B01`. Le callee de sortie `140AC6AA0..140AC6B40` initialise
aussi deux tables fixes de 336 et 4 200 octets (42 × 8 et 210 × 20). Leur sens,
leurs consommateurs et leur redimensionnement restent à établir. Ce callee
n'est pas identifié comme un allocateur. Le chemin après `140B20B29` atteint
`14B3C5D01`, hors des pages actuelles.

Les instructions sont lues après le restart : aucune exécution complète de la
boucle, attribution globale des writers ou sémantique d'allocateur n'est inventée.
Cinq pages déjà connues correspondent aux hashes 9F ; la page `141238000` diffère
de l'ancien hash et sa nouvelle identité est conservée. Les corps effectivement
lus restent distincts d'une image retail intacte ou d'un contrat de protocole.

**48 reste non livré.** La suite utile est le port cohérent des pools,
initialisations, réservations, tables/références et données client, puis les
mesures en combat et multijoueur. Garder l'allocation à 24 jusqu'à qualification
de ce candidat complet. Le besoin exact est 48 zombies ordinaires **plus** les
places des spéciaux, suivi dans [Server #324](https://github.com/maxis0191/iw7-paris-server/issues/324).

## Reprise demandée le 19 octobre 2026

L'objectif humain est désormais **48 zombies ordinaires plus des places pour
les ennemis spéciaux**. Il ne s'agit pas de partager 48 places entre tous les
ennemis. Le nombre de places supplémentaires devra être dimensionné avec les
réservations natives des cinq cartes ; aucune capacité étendue n'est livrée.

La reprise du capteur autorise le pin moteur cfca45b1 dans le seul profil
diagnostic isolé. Son scheduler a exactement le même blob Git
`d235aeee97891254b1c38b7841e01700e130220d` que les deux pins déjà admis.
Les transformations et leurs empreintes restent identiques. Les tests passent
par le vrai script Apply et conservent le refus des sources inconnues, du
profil ordinaire et des autres pins. Cette qualification de source ne prouve
ni canary matérielle, ni writer, ni capacité supplémentaire ; il faut ensuite
mesurer le dédié privé, sans employer Main ou le client occupé.

Le runner dédié seul n'installe plus les scripts gameplay Server, absents des
exports Native. Il sauvegarde et retire temporairement les seuls GSC candidats,
emploie une configuration CP retail minimale à 24 agents, puis restaure la
transaction. Il exige un build dont le heartbeat est supprimé, un mot de passe,
loopback et `sv_lanOnly=1` dans les arguments et la configuration. Les profils et
la banque candidats restent sauvegardés ; aucune donnée de Main n'est employée.

Le premier essai de reprise a réellement compilé le diagnostic E903C4C5 et
exécuté le dédié seul, privé, sur 27946. Les deux rôles scheduler ont démontré
leurs canaries matérielles ; un seul `map_restart` vide a produit 18 événements
d'écriture. Les RIP après écriture sont `1412BFCD9` (reset), `14C1ED66C` (compte
redevenu 24) et `14BFE5A30` (pointeur redevenu non nul). Ce sont des sites observés,
pas encore des propriétaires/instructions/allocateurs attribués.

L'essai reste **échoué** : l'accusé final de fermeture du capteur manque. Le
dédié exact a ensuite quitté normalement (code 0), la transaction est restaurée
et la réservation libérée. Le journal original est conservé. La correction
évite de recréer des tickets pour un rôle déjà fermé et permet l'acquittement
d'un ticket non réclamé ou publié seulement après fin de son thread original
et fin du helper ; un ticket réclamé ou une notification active restent protégés.
Le prochain essai doit confirmer cette fermeture. Une option du runner conserve
ensuite uniquement les pages explicitement sélectionnées depuis ce journal,
avec double comparaison et fermeture du handle de lecture. La première sélection
de trois pages est conservée comme API, sans avoir été exécutée.
Une autre adresse observée exige une nouvelle sélection ; aucun scan n'est ajouté.

La recherche dans les archives locales a aussi retrouvé un état plus avancé
que les notes intégrées : le commit historique `e75abe4f` fermait déjà les
checkpoints avant l'arrêt du helper. Son garde `helper_stop` est repris ici dans
la registration et la décision de ticket. Le reçu local 9F du 7 octobre décrit
18 écritures et une fermeture complète en 1 281 ms, puis des lectures bornées
des continuations. Il conserve explicitement `Capacity48Ready=false` et
`AllocatorIdentified=false`. Ces preuves historiques ne qualifient pas un nouveau
binaire ; elles servent à poursuivre l'analyse plutôt qu'à rejouer les anciennes
commandes ou à restaurer leur laboratoire retiré.

La sélection actuelle `writer-path-20261019` réunit huit pages (32 KiB conservés,
16 lectures/64 KiB lus) : les deux writers observés, leurs continuations
`140406000/140B20000`, les cibles de remplissage/base-init `1412BF000/141238000`,
puis les deux seuls compléments manquants proposés par 9F : `14B538000/140AC6000`.
Le rapport historique relie les deux derniers au jump `140B20B1A` et au call
`140B20B23`. Leurs noms ne certifient pas un allocateur ni l'exécution complète
de la boucle. Aucune commande de capture historique n'est réutilisée.

The complete isolated native build from1bcb19c now compiles and links, executable
A29488DF and matching PDB verified with all32 source hashes. This includes the
reviewed actual-context checkpoint TU and scheduler overlay. The next vacant
retail dedicated run must still prove real hardware canaries, observed writers
and cleanup; no48-agent capacity patch follows from compilation alone.

## Actual debug-register checkpoint candidate - 2026-10-07

The next isolated candidate obtains CONTROL|DEBUG context on two exact owned
threads through a helper checkpoint outside the scheduler callback mutex.
It requires the returned flags before reading Rip/EFlags/DR, rejects foreign
debug registers or a pre-existing suspension, performs hardware canaries and
requires exact readback/restoration of all six registers. Only its own suspend
increment may be resumed. No alternate import or SetThreadContext bypass is used.

Review found a publication race: a target could acknowledge ticket0 before the
helper's final SetEvent while helper_inflight was already false. The shared
completion function now retains inflight through ticket3 and that notification,
then releases it. A deterministic stalled-notification test proves closure stays
refused. Small Win32 tests pass normal/expired/after-set/pre-suspended cases with
getter flags100011, real canary flags10005F, exact restoration and zero resume
errors. These tests do not establish retail behavior or thread coverage.

Persistent scheduler transforms surround Apply-DebuggerOverlay: Before removes
only exact known watcher bytes; After requires the pinned profiler baseline and
adds the isolated macro after the PCH. Unknown edits are preserved/refused.
Normal profiles remove the watcher overlay. Build receipts bind pin/helper/source
hashes and keep Ready=false. A Win32 API hang cannot promise a hard200ms bound;
pending claimed checkpoints retain handler/handles and prohibit confirmed cleanup.
Full TU, real lab canaries, vacant restart and writer attribution remain required.

## First native observer attempt - 2026-10-07

The vacant server-only case `watch-server-20261007-014746-895-0993d99e0f0c41b7aae572461176a6aa`
ran native `3B9F0311`. Its private exception CONTEXT flags were `0x10004F`,
which excludes `CONTEXT_DEBUG_REGISTERS`. The observer refused before saving or
programming debug registers: no canary was attempted and no map restart was
authorized. Zero fields in that unavailable register group prove nothing about
existing hardware breakpoints. Pool count24 was observed; its writer was not.

The journal confirms cooperative cleanup; the owned server then exited with
ordinary quit0 after real vacancy, restoration passed, and the lease was released.
Base client and Main were untouched. The next diagnostic must obtain a valid
debug-register context through a reviewed mechanism; merely adding a context
flag does not make absent registers valid. No capacity patch is justified yet.

État du 6 octobre 2026 : recherche uniquement, capacité normale conservée à
24 agents. Aucun patch de capacité, nouvelle capture, build de capacité,
déploiement ou test en jeu n’a été effectué. Les passes statiques admises sont
décrites ci-dessous. Le précédent candidat allouant
64 agents reste retiré après son échec au démarrage.

L’[inventaire JSON](../ops/agent-capacity/inventory.json) contient les adresses,
identités des preuves, propriétaires de fonctions et niveaux de confiance.
La [recette bornée](../ops/agent-capacity/recipe.json) sépare la lecture légère
exécutée, les huit décompilations terminées et la prochaine sélection préparée.
[RUSH-AUDIT.md](RUSH-AUDIT.md) conserve l’incident et distingue le fournisseur
continu de zombies de l’allocation native des agents.

## Preuves retrouvées et contrôlées

Le worktree conservé rhino-animclass contient les fichiers ignorés
`runtime/rush-audit/live-text.bin` et `agent-64-crash.dmp`, lus sans accès à un
processus. Les références existantes du checkout principal,
`tools/references/unpacked-{text,rdata,pdata}.bin`, ont fourni de petites tranches
d’instructions et leurs métadonnées d’exception. Leurs trois SHA-256 correspondent
à [LATE-JOIN-AUDIT.md](LATE-JOIN-AUDIT.md). Les tailles et empreintes complètes
figurent dans le JSON ; les dumps, assets, listes d’instructions et sources
retail décompilées restent locaux et ignorés.

Ces captures sont différentes et datées. Le sélecteur à `0x140C18D00` est détourné
dans le candidat ayant échoué. La référence conserve son entrée normale et la
limite de 24, mais contient aussi d’autres patches du mod. Elle ne représente donc
ni un retail intact, ni nécessairement le binaire exécuté aujourd’hui. Un futur
hook devra contrôler les signatures et structures du candidat réellement testé.

Le minidump confirme une lecture invalide à `0x14044949A`, cible `0x4D10`, avec
RAX nul. RSI vaut `0x143D30C40`, exactement
`g_entities(0x143D22610) + 58 * 1016`, sans reste. Le collecteur part de l’entité
18, parcourt le nombre d’agents et lit le pointeur à entité + `0x190`, puis le
champ à pointeur + `0x4D10`. L’échec historique atteint donc l’entité 58 sans ce
pointeur. Ignorer le pointeur nul ne réserve ni ne construit les agents manquants.

## Invariants à modifier ensemble

| Invariant démontré | Propriétaire ou adresse | Travail nécessaire pour 48 |
| --- | --- | --- |
| Sélecteur limité à 24 | `0x140C18D00`, limite à `0x140C18D76` | Modifier sa politique avec les allocations et tous les consommateurs. |
| Nombre stocké sur un octet | Setup `0x140C19B00`, écriture `0x140C19B22`, `GameStateInfo + 0x546` | Retrouver les allocateurs ; 48 tient déjà dans l’octet. |
| Bornes 18 / 42 / 58 | Initialisation `0x1405AFFC0`, globals `0x144C6F20C`, `0x144C6F208`, `0x144C6F210` | Conserver 18 joueurs et prévoir 66 personnages ; résoudre la réserve intermédiaire avant les entités de carte. |
| Pool serveur et collecteur | Propriétaire logique `0x140449450`, pool `0x143C986B8`, nombre `0x143C986C0`, pas `0x5010` | Identifier allocation/libération/reset et tous les accès ; réserver et relier chaque entité d’agent. |
| Pool SV indexé distinct | `0x140C18DC0`, accesseur `0x140C1A290`, pointeur `0x146B2C508`, pas `0x3F08` | Agrandir et initialiser également ce pool indépendant. |
| Table de références de personnages | `0x140449260`, `0x140449330`, pointeur `0x143F9B358`, 42 entrées de 64 octets | Allouer 66 entrées et aligner les deux parcours, leurs appelants et leur schéma. |
| Restauration de référence d’agent | `0x1404494E0`, limite à `0x1404494FB` | Aligner les indices 1 à 48, avec 0 pour null, sur le pool réel et la compatibilité des sauvegardes. |
| Classification des entités | `0x140073C90`, début via `0x144C6F210`, fin exclusive 2046 | Réconcilier les ranges agents/corps/carte, les sentinelles et les recherches. |
| Parcours client des personnages | Propriétaire logique `0x1401823C0`, boucle `0x1401833AF` / `0x1401833DA`, `CG_GetEntity = 0x140080400` | Agrandir les vrais tableaux et analyser le propriétaire complet, modèles et animations inclus. |
| Recherche client par personnage | `0x140184660`, limite à `0x14018466E` | Aligner 66 sur l’allocation et la durée de vie des données virtuelles par client. |

L’intervalle `[42, 58)` contient 16 indices. Leur répartition complète entre corps
et autres réservations reste **inconnue**. Le début hypothétique des entités de
carte à 82 suppose que conserver ces 16 indices est correct : `18 + 48 + 16`.
Ce résultat arithmétique ne démontre pas une spécification de pool de corps.
Les réservations doivent précéder l’attribution des entités ; déplacer une borne
après leur création modifierait leur classification et leurs références.

Le SDK épinglé nomme `gentity_s::agent` le champ à entité + `0x180`, tandis que
le collecteur observé utilise entité + `0x190`. Le source et les instructions
confirment cette divergence. Le type et la disposition CP doivent être résolus
avant d’employer ce membre du SDK dans un patch. Le pas d’entité de 1016 et
l’adresse de `g_entities` correspondent, eux, exactement à l’index du crash.

Les deux pas d’agents sont distincts : agrandir le pool `0x5010` ne redimensionne
pas le pool `0x3F08`, les réservations d’entités ou les données des personnages.
Changer une dvar et le sélecteur ne corrige pas non plus les 42 entrées de
sérialisation ni la limite de restauration à 24.

## Sauvegardes, snapshots et clients

Les routines de références montrent des indices bornés et des tables de
42 entrées. Le format externe, ses versions, la taille des allocations et leurs
appelants restent à établir. Elles ne doivent pas être qualifiées de codecs de
snapshot sans suivre leurs appelants. Passer de 42 à 66 entrées exige une
politique explicite pour les anciennes sauvegardes : une longueur différente
peut décaler les données suivantes même si l’entier stockant l’index accepte 48.

La borne d’entité 2046 peut numériquement accueillir un préfixe de 82 indices.
Cela ne prouve pas que tous les champs réseau le peuvent. 66 personnages
dépassent 64 ; un éventuel index sur six bits demanderait une modification
compatible, mais **aucun champ de six bits n’est démontré ici**. Les encodeurs,
décodeurs, flags, tableaux client, modèles, animations et corps doivent être
suivis avant de décider si le protocole ou une négociation de capacité change.

Les consommateurs client limités à 42 sont démontrés. Un démarrage serveur seul
ne démontre donc pas la compatibilité de 48 agents avec le client normal.
Le candidat de référence devra disposer d’un client correspondant et revu,
sauf si une négociation existante complète est effectivement démontrée.
Les binaires de Main et le client occupé du propriétaire restent préservés.

## Lecture légère exécutée : corps et limites réseau

La passe a exploité les mêmes fichiers, sans Ghidra, nouvelle capture ni jeu.
Les limites de la recette ont été respectées :

1. Examiner au plus 1 KiB autour des prédicats `0x140073C90` et `0x140073CC0`,
   puis suivre au maximum huit propriétaires complets reliés aux bornes de
   personnage/carte. Pour chaque sous-range, établir le test de classification,
   le type réel, les indices initiaux/finaux et le chemin de création/recyclage.
   Un prédicat de type d’entité ne doit pas être confondu avec une borne d’index.
2. Rechercher des indices de tables de champs réseau dans la rdata existante,
   avec au plus 32 résultats conservés, puis inspecter uniquement les fonctions
   d’encodage/décodage réellement référencées. Maximum huit propriétaires de
   8 KiB chacun. Une preuve de largeur doit relier le champ et sa plage à la
   même table ou paire encodeur/décodeur ; une constante isolée égale à six ne
   suffit pas. Si ces racines ne sont pas identifiées, la largeur reste inconnue.

La lecture des octets et des métadonnées peut rester légère. Un scan complet de
code, une propagation de types ou une décompilation doivent ensuite recevoir
leur propre admission Analysis ; ils ne doivent pas empiéter sur le test en jeu
réservé. La passe n’a suivi aucun propriétaire supplémentaire faute de racine
vérifiée. Aucun scan global des instructions n’a été lancé.

Le prédicat feuille complet `[0x140073CC0, 0x140073CD1)` accepte exactement
les valeurs 6 et 14 : `(type - 6) & 0xFFFFFFF7 == 0`. Son appelant complet
`[0x140449430, 0x14044944A)` possède un record unwind et charge le champ
DWORD à `rdx + 4`. Les deux feuilles `0x140073C90` et `0x140073CC0` n’ont
pas de record unwind ; leurs deux branches de retour ont été lues. Cela
distingue un prédicat de type de la borne d’index, sans attribuer un nom retail
aux types 6/14 ni prouver leur lien avec les corps. Les signatures SHA-256
des trois corps complets figurent dans le JSON.

La recherche ciblée dans la rdata a retrouvé seulement `clientNum` à
`0x141445B50` et `number` à `0x1414491C8`, sans pointeur direct vers ces noms
dans cette même section. Aucun propriétaire de codec n’en découle. Les
références RIP/RVA, les tables sans noms et les données modifiables ne sont
pas couvertes : ce résultat négatif ne démontre pas leur absence.

Le [lecteur reproductible](../ops/agent-capacity/inspect_retained.py) vérifie
les trois empreintes d’entrée et écrit uniquement un rapport neuf sous
`runtime/agent-capacity/`. Il ne conserve pas les octets retail.

La prochaine analyse bornée doit partir de références décodées vers
`0x144C6F208` et `0x144C6F210`, réunir leurs propriétaires unwind et sélectionner
au plus huit fonctions de 8 KiB pour la création/recyclage des réservations.
Pour le réseau, il faut d’abord une racine vérifiée de table ou de codec issue
d’un symbole, appelant ou diagnostic existant ; ensuite seulement suivre
encodeur et décodeur pour un champ précis. Une passe xref globale ou une
capture complémentaire de données exige une admission séparée.

## Passe xref admise et nouvelles allocations

Une réservation Analysis de 4 GiB physiques / 6 GiB de commit a couvert une
passe unique des spans pdata existants. La lease a été libérée et l’absence
de lease active contrôlée. Le rapport ignoré
`runtime/agent-capacity/xref-owners-20261006.json` contient 149 propriétaires
candidats, dont 32 retenus, avec au plus 64 KiB par propriétaire. Le lecteur
a décodé 19 046 142 octets et résolu toutes les chaînes unwind. Cependant,
4 239 records présentent un décodage incomplet ; feuilles sans pdata et
xrefs indirectes ne sont pas couvertes. Une absence de résultat n’est pas
une preuve d’absence de consommateur. Les priorités writers puis adresse
peuvent exclure des lecteurs tardifs : le rapport ne clôt pas les 149 candidats.

Le propriétaire SV complet `[0x140C1A190, 0x140C1A21E)` réunit trois records.
Il prend le compte dans ECX et réserve deux blocs alignés à `0x80` :
`compte × 0x3F08` publié dans `0x146B2C508` et remis à zéro, puis
`compte × 0x88` publié dans le contexte à `+0x28`. Le compte est conservé
à `+0x30`. Pour 48, cela représente respectivement 774 528 et 6 528 octets.
L’appelant et le compte réellement transmis restent à suivre.

Les writers `0x140B1F4E0` et `0x140486E70` réservent `0xA88` octets, soit
`8 + 42 × 64`, avec alignement 8, puis publient la table `0x143F9B358`.
Le constructeur `[0x1404491E0, 0x140449201)` appelle le constructeur de base
`[0x140434FB0, 0x140435025)`, qui construit exactement 42 lignes de 64 octets
à partir de `+8`. Pour 66 personnages, la taille correspondante est `0x1088`
(4 232 octets). Taille, boucle de construction, deux routines de références
et données client doivent changer ensemble. Les tags de mode 1 et 2 observés
ne suffisent pas ici à certifier la variante CP. Les owners `0x14048ABF0` et
`0x140B21DD0` réinitialisent le pointeur ; la destruction complète demeure
à suivre. Les nouvelles signatures et limites sont dans l’inventaire.

Le wrapper [Invoke-XrefAnalysis.ps1](../ops/agent-capacity/Invoke-XrefAnalysis.ps1)
réserve le scheduler et limite le processus possédé à 180 secondes. Les cinq
tests synthétiques du lecteur vérifient union des spans disjoints, alignement
du chain record, cycle, parent manquant et données unwind hors capture.
Aucun jeu, Ghidra ou patch moteur n’a été lancé par cette passe.

## Décompilation bornée préparée

La recette Ghidra prévoit une admission Analysis exclusive de 4 GiB physiques
et 6 GiB de commit. Elle désactive l’analyse automatique de tout le programme,
sélectionne sept propriétaires simples bornés par unwind et limite chaque
fonction à 30 secondes. Elle ne doit pas tourner pendant un scénario en jeu.

```powershell
./ops/Debug-Server.ps1 -Action Decompile `
  -ReferenceRoot '<répertoire existant des références vérifiées>' `
  -GhidraRoot '<installation Ghidra existante et épinglée>' `
  -FunctionList ./ops/agent-capacity/functions.csv `
  -OutputPath '<nouveau chemin absolu dans runtime/agent-capacity, extension .c>'
```

Le helper effectue déjà l’admission : ne pas ajouter une réservation imbriquée.
Ses résultats restent ignorés. Les petites fonctions sans unwind utilisent les
ranges Capstone explicites de la recette, sans prendre les octets suivant un
retour pour du code ou arrêter la lecture au premier branchement conditionnel.

Le helper `DecompileSelected.java` a été corrigé avec accord technique. Il
réunit les spans de même racine unwind, refuse cycles, profondeur supérieure
à 32, parent manquant, adresse de fragment et union supérieure à 64 KiB.
Le CSV et les cinq arguments publics restent identiques. Le résolveur Java
exact a passé neuf cas synthétiques et quatre propriétaires retenus complets
sans charger Ghidra ; la décompilation intégrée reste non exécutée.
La prochaine sélection de huit racines est
[allocator-functions.csv](../ops/agent-capacity/allocator-functions.csv).
Elle conserve les cinq entrées déjà préparées et ajoute le second writer de
table, le collecteur de références et le stockage client chaîné. Le premier
CSV simple reste inchangé. Objectifs : relier le compte transmis à l’allocateur
SV, attribuer réellement les tags de mode, puis établir création/recyclage des
corps et bornes des consommateurs client. Le pool de stride `0x5010`, la
répartition des 16 réservations et les codecs restent des inconnues.

La sélection distincte [aim-functions.csv](../ops/agent-capacity/aim-functions.csv)
contient seulement les deux propriétaires UI confirmés `0x140615A50` et
`0x140601170`. Une lecture locale de 723 octets, sans scan global, confirme que
le second propriétaire `[0x140601170, 0x140601226)` effectue une conversion
de coordonnées à partir d’un record de viewport vers deux sorties du caller.
Sa signature SHA-256 est
`1e4c7fd6f0df7c6f7dd20ef8f798b1dbbcde2c66a706930dda38742590f1c7a7`.
Ce maillon ne démontre aucune écriture de usercmd ou d’angles de vue.

La recette distingue ces owners prouvés des noms `QueueMouseInput`,
`cl_bypassMouseInput`, `sensitivity`, `m_pitch` et `m_yaw`, encore sans
producteur/consommateur identifié. La prochaine passe devra relier les noms
à leurs registrations, prouver la file bornée et sa consommation en yaw/pitch,
puis expliquer les guards UI/focus et transformations. Aucun CSV ne présente
ces noms comme des fonctions certifiées. La future mesure utilisera des
impulsions `dx/dy` bornées et des angles serveur frais, sans écrire directement
les angles ou la position. Les deux sélections réutilisent le helper admis,
avec union maximale de 64 KiB et timeout de 30 secondes par propriétaire ;
elles n’ont pas été exécutées dans Ghidra.

Un fragment unwind n’est pas une fonction entière. Le collecteur comporte
`[0x140449450, 0x140449462)`, `[0x140449462, 0x1404494D1)` et
`[0x1404494D1, 0x1404494D7)`. Le parcours client a sa racine à `0x1401823C0`
et au moins deux continuations chaînées jusqu’à `0x140183488`.
Les deux propriétaires restent hors du premier CSV simple, conservé à sept
fonctions. Le helper réunit désormais leurs enfants `UNW_FLAG_CHAININFO`,
mais seul un futur résultat Ghidra contrôlé pourra fournir un graphe d’appels
décompilé exploitable.

La passe xref exécutée cible les sept globals du JSON, uniquement via
des instructions réellement décodées. Elle a sélectionné 32 propriétaires
et limité les corps réunis à 64 KiB par propriétaire. Priorités suivantes : allocateurs manquants,
écritures/lectures des comptes, reset/libération, réserve de 16 indices, schémas
save/snapshot et données client. Chaque patch futur exige son invariant et sa
signature ; remplacer aveuglément toutes les constantes 24/42/58 ne suffit pas.

Le passage à un candidat natif réversible vient après fermeture de ces inconnues.
La validation isolée devra montrer 48 acteurs distincts réellement reliés,
sauvegardes/références, recyclage des corps, modèles/animations client,
réservations de boss/événements, changements de carte et stress multijoueur.
Admission du scénario complet et acceptation du propriétaire restent distinctes.


## Prochaine sélection pool et appelant

Le rapport existant conserve 149 racines, mais ses 117 exclusions ne contiennent
pas les sites xref. Aucun des 32 propriétaires retenus ne contient un appel
direct à `0x140C1A190` ni un accès à `0x143C986B8/C0` ; cette absence dans
une sélection plafonnée ne clôt donc ni l’appelant ni l’allocateur du pool.

Le lecteur préparé place les producteurs/écrivains de `0x143C986B0/B8/C0`
avant le quota de 32, puis les appels directs dont la cible exacte est
`0x140C1A190`, les lecteurs du pool et les autres candidats. Dans une même famille, écrivains,
producteurs d’adresse et lecteurs précèdent l’ordre d’adresse stable.
Les exclusions futures conservent leurs sites et leur priorité, même si le
quota laisse un propriétaire du pool en attente. Aucune recherche globale
de la constante 24 n’est ajoutée.

`Invoke-XrefAnalysis.ps1 -RetainedReport <rapport existant>` permet de revisiter
les 149 racines seulement ; leurs hashes, couverture, unicité et borne de
256 candidats sont contrôlés. Ce mode ne retrouvera pas un appelant ou un
owner ne référençant que B0 situé hors de cette liste. Pour ces racines
manquantes, la prochaine passe unique admise omettra cette option et parcourra
les spans pdata existants, avec recherche limitée aux cibles nommées.
Ces deux modes restent soumis à Analysis 4 GiB / 6 GiB ; aucun n’a été lancé
pour cette préparation. Onze tests synthétiques passent, dont le dépassement
du quota par des writers génériques, la priorité du pool/appelant et le refus
d’un rapport incomplet, dupliqué, modifié ou trop grand.

La sélection Ghidra déjà préparée reste le CSV de huit propriétaires
`allocator-functions.csv`, sans duplication. Les installations existantes
Ghidra 12.1.4 PUBLIC et Temurin 21.0.12.1+1 ont été vérifiées par leurs
métadonnées/version Java. Après libération et admission séparée, la commande
est la suivante, avec les deux racines d’outils/références existantes et un
nouveau chemin `.c` sous le runtime ignoré du worktree :

```powershell
pwsh -NoProfile -File ./ops/Debug-Server.ps1 -Action Decompile `
  -ReferenceRoot $ReferenceRoot -GhidraRoot $GhidraRoot `
  -FunctionList ./ops/agent-capacity/allocator-functions.csv `
  -OutputPath $NewIgnoredCPath
```

Le helper prend lui-même la réservation : ne pas imbriquer une seconde lease.
Le script refuse une union de spans supérieure à 64 KiB et limite chaque
décompilation à 30 secondes ; `-noanalysis` évite l’analyse automatique globale.
Les preuves attendues sont la provenance du compte ECX de C1A190, son mode et
sa durée de vie, puis le producteur/libérateur du pool de stride 0x5010 et
les ranges de corps réellement construits. Réseau et largeur de champ restent
inconnus tant qu’une racine de codec n’est pas démontrée.


## Résultat Ghidra des huit propriétaires

La passe coordonnée par le parent a terminé les huit décompilations du CSV,
sans analyse automatique globale ; sa réservation a été libérée. Le log
`runtime/agent-capacity/allocator-selected-next.log` confirme chaque union
complète, dont SV `[0x140C1A190, 0x140C1A21E)`, collecteur
`[0x140449450, 0x1404494D7)` et client
`[0x1401823C0, 0x140183488)`. Les autres spans, les hashes du CSV et du
script d’union figurent dans l’inventaire. Le résultat dérivé reste ignoré.

Le contexte de l’allocateur SV provient de `0x146B22AC8`. Le compte reste
stocké à `+0x30`, avec le second bloc à `+0x28` ; cette décompilation ne révèle
pas encore l’appelant qui fournit le compte. Le constructeur de table confirme
les 42 lignes de 64 octets à partir de `+8`. Une signature récupérée par Ghidra
omet l’argument transmis au constructeur de base : la preuve assembleur déjà
établie garde priorité sur cette inférence de type.

Le collecteur révèle un niveau d’indirection concret : il parcourt le compte
`0x143C986C0`, les octets actifs à `0x143CA1612` et des records à
`0x143D26D80` de stride `0x3F8`. Le pointeur du record à `+0x190` mène à un
entier à `+0x4D10` ; cet index moins un sélectionne une ligne de la table
personnages `+8`, stride `0x40`, avant l’appel `0x140437DB0`. Il faut donc
retrouver le producteur et la durée de vie de ce pointeur ainsi que les bornes
de l’index ; il ne suffit pas d’agrandir le pool de stride `0x5010`.

Le propriétaire client complet consomme `0x144C6F208` et écrit des octets
indexés à `contexte + 0x86B17`, puis la ligne propre au client. Sa reconstruction
du pointeur de contexte est obfusquée ; aucune taille d’allocation garantissant
66 personnages n’est déduite de cette seule boucle. La partition des corps,
les producteurs/libérateurs du pool et les codecs réseau restent inconnus.
La passe xref prioritaire préparée doit maintenant relier ces consommateurs
aux producteurs et au compte de l’appelant, avant toute proposition de patch.


## Appelant et réservation : lecture prioritaire suivante

La passe xref complète coordonnée par le parent a retenu 32 des 167 candidats,
avec zéro chaîne unwind non résolue et toujours 4 239 records incomplets.
L’ancien classement laisse l’appelant après 74 lecteurs du pool ; son site
conservé dans les exclusions a permis de lire le propriétaire complet de
331 octets, sans refaire le scan. Le classement préparé est maintenant :
producteurs/écrivains du pool, appelants exacts C1A190, lecteurs du pool, autres
candidats. Deux tests supplémentaires empêchent les lecteurs de noyer l’appelant et un écrivain hors pool de promouvoir un simple lecteur du pool.

À `0x140C56B76`, l’owner `[0x140C56A90, 0x140C56BDB)` transmet ECX=EDI à
C1A190. EDI vaut zéro si le champ du contexte appelant `+0xCF` est actif ;
sinon il provient du byte `GameStateInfo + 0x546`, seulement lorsque le prédicat
`0x1406E6770` l’autorise. Le source épinglé nomme ce champ `agentMaxCount` et
certifie son offset dans `game/structs.hpp`. Le getter `0x140E7AD70` est aussi
identifié par `component/ranked.cpp`, qui peut lui substituer un état privé :
le mode exact et le producteur du champ doivent donc rester reliés à l’état
réel. Le prédicat vérifie `0x1405AFDE0(3)`, une seconde condition
`0x1405AEBA0` et un compte positif ; son second test n’est pas encore nommé.

Le même appelant transmet ce compte à `0x140C56BE0` pour réserver l’arène
avant les allocations SV, puis appelle l’initialisation personnages tag2.
La leaf sans pdata `[0x140C1A230, 0x140C1A24B)` retourne exactement
`align128(compte × 0x3F08) + align128(compte × 0x88)` : la réservation et les
deux sous-allocations doivent rester cohérentes, pas seulement le compte lu.
Le budget global ajoute aussi des tailles client et serveur distinctes.

Deux autres dépendances sont maintenant concrètes. L’owner `0x140445FE0`
sépare à l’index 18 : au-dessus, il lit le pool B8 avec `(index − 18) × 0x5010`
et le champ `+0x4CFC` ; en dessous, un stockage distinct utilise `0x7218`.
L’encodeur de références `0x140449600` soustrait la base B8, convertit le
pointeur en index plus un et refuse un index supérieur à 24. Cette borne
appartient donc aux références à réviser pour 48 ; ce n’est pas encore une
preuve de largeur de champ dans un paquet réseau.

B0 n’est pas le pool d’agents de stride 0x5010 : les owners `0x1400BA830` et
`0x1400BB710` convertissent une référence de champ `+0x198` avec un stride
0x1F88, zéro pour null et index plus un. La paire transfère quatre octets,
mais son contexte de persistance et son éventuel lien avec les snapshots
restent à établir. Ces rôles ne doivent pas être fusionnés depuis la seule
proximité des globals B0/B8.

Le CSV `pool-caller-functions.csv` a servi à la passe Ghidra admise de huit
propriétaires : appelant, réservation, taille serveur, encodeur, consommateur
d’index, mise à jour serveur et paire de références. Le nom historique
`server_entity_recycle_consumer` n’est pas une preuve de recyclage. Il exclut les leaves sans
pdata, déjà lues de manière bornée. Aucun patch candidat n’est encore proposé :
producteur/libérateur du pool, stockage de records 0x3F8, partition/recyclage
des corps, encodeur/décodeur réseau et bornes d’allocation client restent à
résoudre ensemble. Les sorties d’instructions dérivées restent ignorées.

L’inventaire non commité a subi une troncature locale lors d’une erreur
d’encodage. Sa copie vide est préservée dans le runtime ; les faits ont été
reconstruits depuis ces rapports, les références vérifiées et le présent
document, puis validés dans un fichier UTF-8 temporaire avant remplacement.
La récupération exacte des anciennes métadonnées est inconnue et explicitement
indiquée ; l’inventaire refuse toute readiness de patch ou compatibilité 48.


## Huit racines pool/appelant : résultat et audit

La passe parent du 7 octobre a terminé les huit propriétaires complets,
soit 331, 153, 66, 295, 97, 1 436, 3 244 et 2 660 octets dans l’ordre du CSV.
Le log `runtime/agent-capacity/pool-caller-selected-20261007.log` confirme
les huit spans et la fin de décompilation ; les sorties restent locales et
ignorées. L’inventaire conserve les bornes exclusives, le hash du CSV et celui
du résultat. La réservation est libérée selon la vérification du parent.

La cohérence de réservation est maintenant démontrée dans le même appelant :
le compte individuel filtré alimente la taille d’arène puis C1A190 avant la
publication de l’état prêt. C56BE0 ajoute les tailles serveur et client,
alignées sur 128 octets, la taille agents déjà alignée, 0x96000 et C68880.
Cela identifie une dépendance à préserver lors d’une extension ; ni le sens
exact du mode ni la construction de B8/C0 ne sont encore résolus.

Attention à la limite d’attribution du décompilateur : les 153 octets de
C56BE0 se terminent par un tailcall B6D2A0. Le C généré développe ensuite des
opérations de cette cible et signale un bloc hors owner. Ces opérations ne
prouvent pas un corps unwind plus grand et ne sont pas attribuées à C56BE0.
L’union pdata complète prouve la couverture des fragments, pas les types,
la pureté retail ni la sémantique inférée des appels terminaux.

B213F0 est une mise à jour serveur. Une boucle de compte C0 lit l’entité à
B8 + index × 0x5010 + 0x4A90, ignore la sentinelle 0x7FF, vérifie le flag actif
et construit le pointeur g_entities + numéro × 0x3F8 avant AF9ED0/B1EF30.
Une autre boucle agents part du slot 18 et appelle C18900. Cela relie le pool
aux entités actives, mais ne démontre ni allocation, ni destruction, ni
partition des corps. Le propriétaire capturé contient aussi un hook mod :
il n’est pas une image stock intacte ni l’identité du binaire actuel.

L’audit léger repasse onze tests synthétiques de classement/réutilisation et
le résolveur Java exact : union, padding, fragment refusé, cycle, parent
manquant, troncature, version, profondeur et taille. Quatre propriétaires
retenus passent aussi la résolution complète sans scan text ni Ghidra.
Les bornes de sortie et hashes des entrées sont contrôlés ; les 4 239 records
à décodage incomplet restent une limite d’absence de preuve, pas une absence
de dépendance. Aucun patch 48, build moteur ou lancement de jeu n’est issu
de cet audit.

Le groupe suivant `pool-lifecycle-functions.csv` ne remplit pas son quota avec
des mises à jour de frame : six racines complètes, 2 744 octets au total,
identifiées par les métadonnées existantes. C68B00 (865) et C54980 (285)
viennent du même appelant d’arène ; leurs premiers fragments ne suffisaient
pas. Le constructeur 449E90 (55), publié dans 143F25A88, et 4458D0 (265),
appelé par 4459E0, servent à retrouver les champs et vtables d’initialisation.
B21DD0 et 48ABF0 (637 chacun) sont les deux teardowns déjà observés ; il faut
séparer remise à zéro de pointeurs, libération réelle et mode avant de les
relier aux pools. Leur lien à B0/B8 est encore une question, pas un fait.

Cette prochaine passe exige une admission séparée. Si aucune racine ne publie
B8/C0, suivre seulement l’indirection démontrée depuis ces constructeurs,
sans ajouter des consommateurs génériques. Il faut la formule d’allocation,
l’initialisation et le reset/free du pool avant les corps et les codecs.
Le compte 48, les 66 personnages et la réserve arithmétique de 82 slots restent
un candidat de dimensionnement ; ils ne sont pas un ensemble d’invariants
validé pour patch.


## Six racines lifecycle : nouvelle contrainte de stockage

Les six décompilations ont terminé dans le résultat local
`pool-lifecycle-selected-20261007.c`. C68B00 construit des blocs serveur
alignés, sans store direct B8/C0 dans cet owner ; C54980 construit les clients
de stride 0xAEA98 ; 4458D0 configure des records de stride 0xC7A8. Ces pools
ne deviennent pas ceux de stride 0x5010 ou 0x1F88 par proximité d’adresse.
Les callees et stores indirects restent des pistes ouvertes.

Une lecture ciblée de 160 octets de la vtable 141477508, publiée par 449E90,
révèle une contrainte supplémentaire cohérente. Le slot +0x38 vise la leaf
242E20 : index non signé inférieur ou égal à 41. Les getters 44A0A0 aux slots
+0x28/+0x30 retournent contexte +0x46B8 + index ×0x2CA0 ; 44A0C0 aux slots
+0x18/+0x20 retourne contexte +0x798F8 + index ×0x70. Leur sens exact doit
encore être relié aux appelants, mais l’arithmétique du stockage est exacte :
0x46B8 +42 ×0x2CA0 +18 ×0x70 =0x7A0D8, taille allouée par B1F4E0 et mise
à zéro par le constructeur. Le checker 42 et ces getters appartiennent à la
même vtable. Ce bloc conséquent s’ajoute aux petites lignes de 64 octets déjà
identifiées ; une extension cohérente ne peut modifier seulement ces lignes.

L’hypothèse arithmétique 66 donnerait une séparation des sous-blocs différente,
0xBC7F8 au lieu de 0x798F8 et une taille totale 0xBCFD8. Ce calcul ne vaut pas
patch : les consommateurs, bornes, mode et durées de vie doivent être reliés.
Le rapprochement numérique de 0x7A0D8 avec 24 ×0x5010 ne démontre pas un pool
agents et est écarté comme explication de cette allocation.

Les teardowns B21DD0/48ABF0 appellent le slot0 de ce contexte avec argument0,
puis effacent le pointeur. Le slot vise 449ED0, qui ne transmet la taille
0x7A0D8 au libérateur que si DL &1. Les appels observés ne prouvent donc pas
une libération du heap ; ils peuvent participer à un reset d’objet sur arène.
Le libérateur effectif d’arène et le producteur indirect B0/B8 demeurent
inconnus. La prochaine racine doit provenir d’un store ou d’une méthode de
cette vtable avec champ concret, plutôt que d’une autre boucle de frame.


## Racine bloquante suivante : producteur indirect B0/B8/C0

Le rapport des 167 candidats ne contient aucun WRITE/LEA exact vers B0, B8
ou C0. Cela n’exclut pas un store depuis un pointeur du bloc englobant.
La passe suivante préparée ajoute quatre cibles RIP exactes : 143C98650
(ancre de bloc candidate), 143C98660 et 143C98668 (pointeur/compte joueurs
lus dans B213F0), et 143F25A88 (contexte construit effectivement observé).
Les écrivains et LEA de ces ancres passent avant les lecteurs dans le quota32.
Un onzième test vérifie que ces quatre producteurs candidats précèdent une
masse de lecteurs ; aucun scan n’a été exécuté pour cette préparation.

Les sources SDK épinglées 77e6d4d ne déclarent pas game::level ou level_locals_t
dans game/symbols.hpp et game/structs.hpp. Elles ne certifient donc pas la base
143C98650. Leur gentity_s suggère agent à +0x180, alors que le chemin CP retenu
lit réellement +0x190 : aucune déduction offsetof n’est admise pour construire
la preuve. Il faut suivre une ancre passée en paramètre jusqu’au store indirect,
calculer son adresse effective et confirmer qu’elle publie B0/B8/C0 avec le
compte et la taille correspondants. Une déclaration ou un getter seul ne suffit
pas. Les éventuels nouveaux owners hors des 167 racines imposent une passe
pdata admise complète, pas une réutilisation silencieusement incomplète.

Commande préparée, non exécutée, après libération et admission :

```powershell
pwsh -NoProfile -File ./ops/agent-capacity/Invoke-XrefAnalysis.ps1 `
  -ReferenceRoot $ReferenceRoot `
  -OutputPath ./runtime/agent-capacity/xref-indirect-anchors-20261007.json
```

La sélection Ghidra ultérieure dépendra des véritables writers/LEA révélés,
avec maximum32 propriétaires complets et64 KiB chacun. Aucune liste de callees
non liés n’est ajoutée pour remplir un quota. Si seuls des lecteurs persistent,
la racine manque encore et la proposition de patch reste refusée.


## Reset exact, fausse ancre rejetée et prochain appelant — 2026-10-07

La passe indirecte a été exécutée. Les deux rapports historiques
`xref-indirect-anchors-20261007.json` et `indirect-producer-selection-20261007.json`
sont conservés ; leur ancienne candidature143C98650 comme base de level est
réfutée. Cette adresse reçoit une registration de dvar. La base effectivement
mise à zéro est143C98660, sur0x8F90octets, ce qui efface B0/B8/C0. Cet effacement
ne prouve aucune allocation ni publication ultérieure de ces trois champs.

La lecture Capstone de3FCC10..3FCD30, exactement288octets, retrouve le SHA256
`e838927623400e8dd269bc7ec1bd2fccc498e7845c18728608c0d5d446045f68` du propriétaire
retenu. Le C Ghidra signale PIC et développe memset comme branche, puis retire
les instructions réellement présentes après3FCC52. Son retour depuis le memset
est donc une représentation incomplète ; ce C ne démontre pas l'absence de suite.
Les instructions effectives rétablissent ensuite143C98670=143F1E610,
143C98678=143D22610,143C98668=le dword146B229E0,143C98660=143CA2060.
La boucle associe chaque entité de stride0x3F8 à son joueur de stride0x7218 par
store à entité+0x170. Aucun store non nul de B8/C0 n'est présent dans cet owner.

Le tailcall final3FCD2B vise434AD0. Aucune entrée pdata ne couvre cette cible,
mais l'entrée est démontrée par le tailcall. Sa séquence de24octets, jusqu'au
jmp terminal434AE3, charge le pointeur143F9B350, ajoute8, met EDX=0 et R8D=0x11EE,
puis saute au memset12BFC90. C'est un helper leaf à transfert terminal, sans
appel ni modification de pile locale ; ce n'est ni un nouveau propriétaire pdata
ni un producteur B8/C0. Son contrat reste une remise à zéro de ce référent.
Aucun CSV n'invente un owner à cette adresse.

La lecture légère autorisée a contrôlé huit owners déjà retenus,6241octets au
total :3FCC10,486550,486D10,48A870,B35190,C71C80,AFA2E0,0BA830. Les autres LEA660
accèdent à flags/bitsets/tables à offsets2480,525C,52F2,5B60,7E60,8660 et8F0C,
sans publier B8/C0. AFA2E0 contient un movabs/jmp de hook hors image capturée ;
sa présence ne certifie pas un owner retail intact. L'audit exact est retenu dans
`runtime/agent-capacity/reset-capstone-audit-20261007.json` ; aucune extraction,
Ghidra supplémentaire ou partie n'a été lancée par cette lecture.

Les32 owners sélectionnés n'ont aucun direct_calls vers3FCC10, mais les owners
exclus des280 candidats ne contiennent pas cette métadonnée. Cette absence locale
ne prouve donc pas l'absence d'appelant. Le SDK épinglé ne donne pas de G_InitGame
retail vérifié ; son hook SV_InitGameVM à14BA3428D est hors texte capturé.

La prochaine passe admise doit ajouter l'appel direct vers3FCC10 comme cible,
puis suivre ses véritables appelants jusqu'à une publication effective B8/C0.
Les ancres660/668/670 peuvent relier reset, joueurs et entités ;650 doit quitter
la priorité producteur puisqu'elle est une dvar. Aucun nouveau CSV de fonctions
Ghidra n'est justifié tant qu'un appelant/store réel n'est pas identifié. Ne pas
remplir un quota avec des consommateurs de frame. Patch48 reste refusé, avec
allocation, compte, stride, durée de vie, corps et codecs encore à relier.


### Recette du prochain xref préparée, provenance limitée

Le helper connaît désormais CALL3FCC10 et les ancres exactes660/668/670 ;650
est exclue des cibles et de la priorité. L'appelant du reset passe avant les LEA
et autres writers pour éviter leur saturation du quota32. Les12 tests passent,
dont une régression synthétique avec74LEA et un fauxwriter650. Aucune analyse
xref n'a été exécutée pendant cette préparation. Après admissionAnalysis4/6,
utiliser la commande `next_reset_caller_xrefs.output_command` de recipe.json,
avec sortie neuve `xref-reset-callers-20261007.json`. Ne pas fournir RetainedReport :
la sélection280 passée ne couvre pas nécessairement les appelants du reset.

Aucun manifest/provenance de capture n'est présent parmi les fichiers existants
de tools/references. Les hashes certifient les références déjà retenues, pas leur
phase de capture ni le binaire source. Des hooks avec transfert hors capture
sont visibles dans les bytes ; une absence de store dans ce texte n'est pas une
absence globale au runtime. Aucune nouvelle copie/capture n'a été faite.

Une éventuelle future capture pré-modifications doit être planifiée séparément.
Au pin77e6d4d, main::set_thread_affinity_mask appelle component_loader::post_unpack,
puis MH_ApplyQueued. Un hook de capture placé avant ces deux opérations serait
plus tôt que les callbacks post_unpack et que leurs detours, contrairement à
un composant ordinaire : le loader trie ses composants par priorité décroissante.
Cela ne suffit pas à certifier pristine : post_start, chargement et post_load ont
déjà eu lieu, avec notamment un callback arxan et d'autres mutations possibles.
Il faudra vérifier décryption/écritures antérieures, comparer les sites de hooks,
et enregistrer sourcepin/overlay, binaire/shipSHA, identitéprocess et base/taille/hash
des sections. D'abord nommer ce résultat pré-component-post_unpack ; ne pas
l'appeler retail intact sans cette preuve. Ce n'est qu'une proposition, sans
édition native, build ou launch. La priorité reste le producteurB8 et son compte.


## Appelants du reset trouvés, CFG externe encore manquant — 2026-10-07

La passe parent `xref-reset-callers-20261007.json` a terminé :32sélections sur281
owners correspondants, zéro unwind non résolu et4239records à décodage incomplet.
Elle apporte deux callsites exacts vers3FCC10 :48855C dans488520..488AFD
(1501octets, SHA256ff35c0636165fbd46a791426589bc706dad87fafb10d6ab484d666e84db79416)
etB20797 dansB20760..B20D91 (1585octets,
SHA256c4e496ce55aba46727572cb5c94d49d09226313a7a5019268e076d9823b5dd3e).
Les deux owners unwind sont complets et leurs hashes ont été revérifiés par
lecture directe, mais ce n'est pas une certification du CFG réellement capturé.

488520 commence par jmp14BF22C47 hors capture et transfère après son callsite
vers14B3785FF ; le décodage linéaire s'arrête488567. B20760 commence par
jmp14BA00414 hors capture, transfère après son callsite vers14BA8E3FF et le
décodage s'arrêteB207B8. Les octets CALL sont certains ; leur accessibilité depuis
l'entrée, leurs arguments et les stores ultérieurs B8/C0 restent inconnus.
Aucun nom G_InitGame n'est attribué. Une adresse14B... peut appartenir à des
régions protégées/Arxan ou transformations ; elle n'est pas automatiquement un
hook mod. Le pin contient effectivement des interventions Arxan post_load et
post_unpack, mais aucun manifest de ces anciennes captures n'en donne la phase.

`reset-caller-selection-20261007.json` conserve ce diagnostic et le CSV
`reset-caller-functions.csv` prépare exactement ces deux owners,3086octets.
La question Ghidra est bornée : peut-on récupérer des arguments/stores capturés
sans transformer les sorties vers régions absentes en absence de producteur ?
Le résultat doit garder les edges externes et le caractère inconnu de
l'accessibilité ; si Ghidra ne voit que le saut externe d'entrée, ne pas répéter
une décompilation pour prétendre résoudre le pool. Il faudra d'abord capturer ou
restituer les régions de code réellement suivies avec provenance et limites de
phase. Aucun nouveau Ghidra/capture/build/jeu n'a été lancé par cette préparation.
Patch48 reste refusé tant que publication, compte et durée de vie B8/C0 ne sont
pas reconstruits.


### Acquisition ciblée réelle, sans interruption du processus

La première intégration Python/Observer sous LabAssetProcess a été refusée dans
la case `20261007-001508-216-60e42105`, avant le client :
`Runtime child is outside its reserved lab.` Le résultat conserve
`Restored=true`, `CleanupError=null`. Le scheduler n'a pas été élargi.
Cette voie runtime est remplacée par `CodePages.cs`, lecteur **in-process** du
parent réservé, avec handle conservé et accès
`QUERY_INFORMATION|VM_READ|SYNCHRONIZE`. Le Python reste un support offline/test.

Le parent a exécuté la lecture le 2026-10-07 à 00:20:48 UTC dans la case
`20261007-001859-322-c7dcac46`, dossier
`capacity-pages-ba1b5da84cb042ad847c0d86c8bcba9d`. Les huit pages de 4096 octets
ont été conservées, avec double lecture stable : 16 appels, 64 KiB lus,
32 KiB de payload, aucun processus enfant. Le handle fermé est confirmé avant
restauration par le contrat CleanupState. La lecture ne fait ni attach debugger,
ni suspension, ni écriture cible. Elle réutilise la lease 14 GiB/15 GiB du parent
et n'en crée/libère aucune.

Identité retenue : PID8224, création `2026-10-07T00:19:06.9017925Z`, binaire
natif SHA256 `72C38CEBD73AA336E973CDCAE6515B3B9BAD8DCEDBE13D6B15F47D08A9208494`.
Les pages sont MEM_COMMIT/MEM_IMAGE, exécutables PAGE_EXECUTE_READWRITE,
allocation base `0x140000000`, mapping `iw7_ship.exe` du candidat. Ce mapping
ne certifie pas une image retail pristine ni une origine Arxan particulière.
La stabilité de chaque page ne garantit pas un snapshot global cohérent.

Les huit SHA256 ont été revérifiés avant analyse avec Capstone5.0.7.
Le manifeste SHA256 est
`cb580b02e07914df1a75b8ed646dc5ca319ffcc2942f0c41ecfeb25f20417960` ;
l'admission sidecar SHA256 est
`f2f7c8a95d8e3be67c34b89c02aec06447a8b9e739b507ea84d1919b26f0e3f4`.
Le rapport dérivé est
`runtime/agent-capacity/live-reset-entry-audit-20261007.json` ; les bytes restent
ignorés par Git. Quatre tests légers du lecteur passent, ainsi que les12 tests
xref. Aucun test pur ne remplace cette preuve live.

### Les deux entrées révèlent le prochain manque exact

Les entrées live des deux propriétaires confirment leurs branches :

| Propriétaire | Destination capturée | Successeur résolu | Prochaine page absente |
|---|---|---|---|
| `0x140488520` | `0x14BF22C47` | `0x14B8E6A6B` | `0x14B8E6000` |
| `0x140B20760` | `0x14BA00414` | `0x14B4B225D` | `0x14B4B2000` |

Chaque destination est un thunk dont les bytes établissent le contrat : sauver
RBP sous RSP, charger la cible par LEA RIP-relative, échanger avec le RBP sauvé,
restaurer RSP, puis JMP vers la cible conservée sur la pile. RBP/RSP sont
restaurés ; cette séquence ne publie ni B8 ni C0. Les deux calculs RIP-relative
sont vérifiés sur les bytes exacts, sans nom de fonction supposé.

Les quatre autres destinations capturées montrent encore des branches sortantes
ou conditionnelles : `14BCE8A4C → 14130D681 / 14BC1567C`,
`14B3785FF → 14C0CF8B7`, `14B7E7350 → 14BAFE22C`,
`14BA8E3FF → 14B431B46 / 140B207DD`, puis ce dernier vers `14C175961`.
Ces chemins ne démontrent pas une allocation ou la publication B8/C0.
La présence des CALLreset dans les propriétaires ne prouve toujours pas leur
atteignabilité depuis l'entrée.

Prochaine demande ciblée : seulement les deux pages des successeurs d'entrée,
8192 octets conservés /16384 octets double lecture, sous une future case détenue
par le parent. Aucun élargissement du graphe, nouveau propriétaire ou patch48
n'est exécuté automatiquement. Il faut d'abord suivre ces deux entrées réelles ;
publication, compte et durée de vie B8/C0 restent inconnus.

Le parent a autorisé ce seul complément. `-PagePlan reset-entry-targets` sélectionne
une seconde allowlist fixe par handle : deux pages, quatre lectures maximum,
16 KiB lus et8 KiB conservés. Le défaut `reset-callers` garde les huit pages.
Aucune adresse arbitraire ne peut être fournie. `reset-entry-plan.json` conserve
les deux thunks et les SHA256 du manifeste/pages parents ; le helper revérifie
ces fichiers avant toute lecture. L'admission et CleanupState restent identiques.
Les tests purs vérifient également le refus d'un nom de plan inconnu, d'une
adresse de l'autre plan, la copie immuable et les bornes du complément.
Le complément est préparé et gelé, sans acquisition par cet agent.

### Complément live : deux appels synthétiques, pas encore le producteur

Le parent a exécuté `reset-entry-targets` dans la case
`20261007-002921-240-e99aee04`, dossier
`capacity-pages-e92179d30b5d4ad48364dab0d1f97212`. Le manifeste complet conserve
2pages,4lectures/16384octets, PID20864 créé à
`2026-10-07T00:29:29.2278549Z`, même natif72C38… que la première capture.
Les deux SHA de pages ont été vérifiés avant Capstone5.0.7 :
`EE80191080BF5FB5C410F77369955F49D39CE2C89ACCF68BAF4A9B5F26F11AFA` et
`4C0372BF38C67B77E2465E2BAC1A294AAC54A5ACE8A32187DFFA1694D4807DB9`.
Le manifeste SHA256 est
`8067a5cb861408f1c1dd98a920a2f29341c0cfb6e5f560f6461eb75fe00f27ba`.

| Chaîne issue de l'entrée | Retour synthétique | Destination d'appel | Prochaine page |
|---|---|---|---|
|488520 →14BF22C47 →14B8E6A6B|1409583B4|140BADAF6|140BADA000|
|B20760 →14BA00414 →14B4B225D|1402A33C8|14B8003D0|14B800000|

Les34octets de chaque bloc sont entièrement décodés. Le premier LEA charge
l'adresse de retour, échangée avec RBP sauvé sous RSP. Un PUSH de RBP puis le
second LEA/XCHG placent la destination sur la pile. RET la dépile : RBP est
restauré et le callee voit RSPoriginal−8, avec le retour synthétique au sommet.
C'est l'effet de pile d'un CALL, sans instruction CALL ordinaire. Les deux cibles
et retours sont calculés sur les déplacements RIP-relative exacts et les formes
d'instructions sont vérifiées. Aucun store B8/C0 ni allocation n'est présent.

Une comparaison limitée à10octets de l'ancien unpacked-text montre à140BADAF6
un MOV sauvegardant RBP puis JMP14BE67544. Cette comparaison historique ne prouve
pas les bytes live actuels : la prochaine demande conserve140BADA000 pour les
vérifier avant de poursuivre. Le second callee14B8003D0 manque entièrement des
captures retenues. Les prochaines deux pages proposées totalisent8KiB conservés
et16KiB de double lecture ; aucune acquisition n'est lancée par cet agent.

Rapport exact : `runtime/agent-capacity/live-reset-entry-targets-audit-20261007.json`.
Le graphe des propriétaires reste incomplet, l'atteignabilité des CALLreset ainsi
que les paramètres d'initialisation et la publication B8/C0 restent inconnus.
Le résultat ne certifie pas une capture pristine ni un patch48 prêt.

### Recul : observer le producteur plutôt que dérouler tous les dispatchers

La poursuite CFG reste utile mais peut exiger beaucoup de pages successives de
code protégé. Elle ne privilégie pas les writes réels des champs. Une stratégie
plus directe consiste à observer **les écritures**, puis récupérer le petit
contexte du site effectivement exécuté. Le contrat proposé est retenu dans
`ops/agent-capacity/producer-diagnostic-plan.json` ; aucun nouveau capteur ni
lancement n'est réalisé par cette revue.

| Option | Gain | Limite actuelle |
|---|---|---|
|Deux pages callees exactes|Lecture sûre,8KiB, même contrat existant|Encore des dispatchers ; B8/C0 producer peut rester lointain|
|Watchpoints natifs opt-in|Identifie thread et RIP du premier write nonzero|Nouveau prototype nécessaire, canary et couverture threads à prouver|
|CDB live attach|Registres/watchpoints sans modifier contenu retail|Pas de wrapper live validé ; attach perturbe, child horsScope, detach à sécuriser|

`Debug-Server.ps1` propose CDB pour dumps offline, pas les watchpoints live.
Son réemploi de lease est lié à l'ancien runtime/isolated-lab, pas au candidat
réutilisé Agent-Lab. `Invoke-DebugTool` tue l'outil au timeout : ce contrat ne
suffit pas pour garantir qu'un debuggee attaché survit. Le CDB AppX épinglé est
horsScope ; le refus du Python ne doit pas être contourné. Une variante CDB
nécessiterait staging de dépendances épinglées dans le candidat, registration
exacte et nouveau contrat de detach, sans élargir le scheduler.

Le capteur natif actuel paris_debugger ne mesure que timings/cadence, pas les
writers. Le pin arxan retire les debug registers lors de post_load/post_unpack,
et son load_import remplace SetThreadContext : la branche exacte
CONTEXT_DEBUG_REGISTERS retourne TRUE sans appliquer. Ces faits interdisent de
supposer qu'une commande hardware watchpoint fonctionne. Ils ne prouvent pas
que toute méthode post_unpack est impossible.

Proposition prioritaire pour le parent/native worker : flag séparé opt-in,
prototype canary privée validé après post_unpack sur les threads server etmain,
puis deux watchpoints8B alignés sur143C986B8/C0 pendant un unique restart du
même dédié vacant vérifié.10s/64events maximum, ring fixe préalloué, aucun IO ni
allocation dans le handler. Chaque événement conserve TID, RIP **après** write,
CONTEXT brut, bitsDR6, valeurs précédentes/nouvelles et phase arm/zero/nonzero.
Les widths/semantics des champs restent inconnus ; observer8B n'en fait pas un
compteur64bits certifié. Toute technique de modification du contexte/VEH doit
réussir la canary avant de lire un résultat moteur.

Il faut30s de réponses UDP0clients, identité exacte, arm acknowledgement puis
un seul restart envoyé par le parent. Les threads réellement armés sont retenus ;
l'absence de write n'est pas concluante si l'initialisation se déroule ailleurs.
Désarmement de tous les threads et retrait du handler possédé doivent être
confirmés avant restauration/release. Un event cap ou timeout conserve le
résultat partiel, sans certification de capacité.

Un RIP de watchpoint désigne le point après l'instruction : retrouver le writer
exige des bytes/CFG bornés, pas une désassemblage arrière aveugle. La suite doit
prouver le champ adressé, le nonzero publié et le contexte allocation/callers.
En parallèle ou fallback, les seules prochaines pages CFG justifiées restent
140BADA000 et14B800000. Le saut historique vers14BE67544 doit être revalidé live
avant d'ajouter sa page. Cette stratégie vise la preuve du producteur ; elle
n'autorise ni patch48 ni annonce de48zombies concurrents.

### Prototype SOURCE ONLY : canary du contexte d'exception

Nouveaux fichiers `src/native/paris_capacity_watch.cpp/.hpp`, sans modification
au manifeste natif72 ni à Build-Voice/fixture existants. Le component se register
normalement mais son post_unpack ne fait rien sans **tous** les flags dédiés
`-paris-capacity-watch -paris-isolated-lab -paris-server-test -paris-debugger`.
L'arm exige en plus CP, password nonvide, tableau clients valide(1..4) et tous
les états CS_FREE pendant30s, contrôlés sur le pipeline server. Aucun client,
maprestart, suspension de thread/process ou commande de jeu automatique.

Interface proposée, à intégrer/compiler puis relire avant runtime :

```text
paris_capacity_arm <nonce16..64 ASCII letters/digits/_>
paris_capacity_stop
```

Une seule acquisition par processus. La sortie fresh est
`iw7-capacity-watch-<PID>-<nonce>.jsonl` dans CWD candidat. Header PID/création
FILETIME, fréquenceQPC, nonce et adresses exactes ; le parent lie le SHA binaire
au manifeste de build, sans certification autoproclamée par le capteur.
Un événement `armed` n'est émis qu'après canary réussie et datawatch installée
sur les deux rôles server/main ; il retient TID/creation/roles. Les rôles peuvent
partager un seul TID : ce n'est pas une fausse couverture de deux threads.
Le parent doit attendre ce record frais, puis envoyer son restart lui-même.

Le prototype n'appelle **pas** SetThreadContext, NtSetContextThread, SuspendThread
ou DebugActiveProcess. Une RaiseException privée sur le thread courant livre son
CONTEXT au VEH ; le handler essaie d'y installer un DR0 sur une canary native8B
privée, puis un InterlockedExchange réel doit produire le single-step attendu.
Cette technique est expérimentale : on ne suppose pas que Windows conserve les
DR modifiés. Sans trap exacte(adresse/DR7/slot) la canary échoue et les champs
moteur ne sont pas armés sur ce thread. Aucun contournement de l'import Arxan
n'est appelé. Tout DR antérieur, même slot inactif, ou TF actif refuse l'arm.

Après cette preuve locale, DR0/DR1 surveillent143C986B8/C0 sur8B. Le ring fixe
64slots conserve CONTEXT complet hex, TID/roles, QPC/tick, slotsDR6, RIP après
write et valeurs brutes previous/current. Aucun IO, allocation, mutex ou stack
walk dans le VEH. Le flush async écrit hors handler. Kind0=canarypass,1=write,
2=failure,3=disarmed. Zéro/nonzero est suivi **par thread** ; si le reset et la
publication ont lieu sur deuxTID, l'analyse doit corréler les événements bruts
et ne pas considérer les flags locaux comme preuve globale d'absence.

Le watchdog10s et le cap64 demandent l'arrêt ; aucun write n'est crédité après
le délai. La fermeture est coopérative, sans suspendre un thread occupé. Chaque
callback possédé restaure ses DR par une seconde exception privée, puis une
**troisième exception** vérifie les registres réellement retournés par Windows.
Un thread original terminé est reconnu uniquement par son handle retenu.
RemoveVectoredExceptionHandler n'est appelé qu'après tous les DR possédés fermés ;
les handles doivent être fermés aussi avant cleanup_confirmedtrue. Un thread
bloqué sans callback peut empêcher cette clôture : le prototype ne l'interrompt
pas et garde le handler/cleanupfalse. Le parent conserve alors la lease et les
transactions, ou établit séparément la fin du dédié exact qu'il possède.

`paris_capacity_watch::cleanup_confirmed()` fournit le predicate C++ au parent ;
`request_stop()` demande seulement un arrêt. Le record final conserve failures,
canary_prerequisite_satisfied, covered_roles et all_init_threads_coveredfalse.
Même des canaries des deux rôles ne certifient pas tous les threads d'init.
Pas de certificat48, pas de capacité modifiée, et canaryfailure=no evidence.

`tests/native/capacity_watch_test.cpp` couvre les invariants purs : nonce,
délai/clockbackward, refus DR/TF antérieurs, canary exacte, suivi zéro/nonzero
par slot et saturation/concurrence du ring sans overwrite. Source de test
préparée seulement ; cet agent n'a lancé ni compilation ni runtime. Le peer
et le parent feront la compilation légère et la revue de la livraison du
CONTEXT, des états d'exception et de la fermeture avant toute activation.

La revue peer a identifié et corrigé deux risques avant compilation : admission
native désormais SV_Loaded +mapname exactcp_zmb +net_port INT27100..27999,
et barrière de registry horsVEH couvrant publication des handles, callbacks
arm/close et décision async de retirer le handler. Un callback retardé ne peut
plus publier un handle après cleanupconfirmé. Le VEH n'acquiert pas ce mutex.
Avant toute restauration DR, le CONTEXT doit encore porter **nos** registres
exacts de la phase courante, ou la baseline déjà restaurée. Une collision avec
un état étranger conserve cleanupfalse et ne l'écrase pas. La vérification par
exception suivante reste obligatoire avant closure.

Les champs previous_b8/c0 désignent la précédente **observation** du même TID,
pas une lecture atomique avant l'instruction. Le read_pair dans le VEH survient
après le trap et peut voir une écriture concurrente d'un autre thread. Le site
watchpoint est une preuve d'accès au champ ; attribuer la valeur nonzero à cette
instruction exige encore opcode/registreCONTEXT exacts. first_nonzero local ne
remplace pas cette validation et ne prouve pas une publication cohérente globale.

### Intégration build et validation pure après revue

Le peer a relu le CPP SHA256
`A3F35AC064B3C743E41D5D464B22FD602AB312C8EEC781C72DFAAC046116C379`
après correctifs et ne relève plus de blocker concret. Le test pur a réellement
compilé et exécuté(exit0) via `runtime/capacity-watch-peer-pure.cmd`, MSVC
`/std:c++17 /EHsc /W4 /WX /Od /RTC1`. Exe mesuré SHA256
`7D9ED11FFC605FAA1DDD875FB4CA2EEDF06BA6E9F24A1BE339B1B01830000B9B`.
La passe peer n'a pas conservé stdout/log séparé : aucun hash de log n'est inventé.
Cette validation remplace le statut antérieur source-de-test-noncompilée ; elle
ne compile pas le CPP Windows/SDK complet ni ne démontre la livraison des DR.

Build-Voice inclut le CPP/HPP seulement avec **IsolatedLab ET Debugger**.
Debugger exige déjà ServerModules, donc le pin77 et son SDK CP. Main et les
profils nondebugger n'incluent aucun TU watcher. Le helper Build-Copy.Core refuse
les sources/cibles redirigées et prévalide les deux hashes avant copy/remove :
un fichier inconnu refuse le changement de profil sans effacer l'autre.
Le profil ordinaire retire seulement la paire exacte précédemment copiée.
Le manifeste réussi conserve CapacityWatchBuild, hashes CPP/HPP et helper ;
compilé ne veut pas dire armé. Le flag opt-in runtime reste absent par défaut.

TestsOnly intègre le test C++ pur et le test PS des copies de profil. Le test PS
a réellement passé dans un dossier synthétique distinct de tools/iw7-mod-native :
copies exactes, retrait au profil ordinaire, refus d'édition inconnue dans les
deux sens sans mutation partielle. AST Build-Voice validé. Aucun rebuild natif
complet ni mutation du checkout d'outils n'a été lancé par cette intégration.
Le parent doit encore compiler le TU complet et coordonner un dédié privé vacant
pour vérifier canary, contexte, journal et fermeture.

### TU complet mesuré et runner dédié seul — 2026-10-07

Le premier build complet a réellement échoué C4018/C2220 (comparaison signed/
unsigned du nombre de clients). Son journal reste
`runtime/capacity-watch-full-build-20261007.log`, avec la copie source échouée
dans `runtime/capacity-watch-first-TU-failure-20261007/`. Le seul correctif est
l'index unsigned de cette boucle. Le retry a compilé et lié avec exit0 ; journal
`runtime/capacity-watch-full-build-retry-20261007.log`, BuiltUtc
`2026-10-07T01:00:22.3364787Z`, manifeste `runtime/voice-package/build-manifest.json`.
Binary SHA256 `3B9F0311F3840697EB798ACBD29616D8D77FEFDD44B46E70EE67AD401CE4C660`,
PDB `81342B2E5D8B470E90768C532A39C6F5712CD575073D5E5844EA54C7A2400163`,
CPP `D8BD87C44680676FB376AF4AC5DA879BC0A3BED440774D20221E5327B5B9DC8C`.
La réservation build était vide à `01:00:42.5967965Z`. Ce résultat compile le
prototype ; il ne prouve toujours ni canary Windows ni producteur B8/C0.

`ops/agent-capacity/Watch-Server.ps1` prépare un dédié stock existant marqué,
sans client, avec une réservation Runtime 6/7GiB, port privé 27100..27999 et
password/RCON éphémères. Exemple après coordination du créneau :

```powershell
pwsh -NoProfile -File ops/agent-capacity/Watch-Server.ps1 -CandidateRoot '<existing-complete-candidate>' -ServerPort 27116 -DryRun
# Même commande sans -DryRun seulement après revue/admission coordonnée.
```

Le parser réutilise le contrôle JSON strict des scénarios : doublons/casse,
champs inconnus, types, identité PID/creation/nonce, séquence 64 événements,
CONTEXT borné, canary de chaque TID avant armed et lignes terminées. Une unique
commande map_restart suit l'ack canary et une nouvelle lecture UDP vacant.
La sortie distingue CanaryOnly, événements write et cleanup natif ; WriterProven,
GlobalInitCoverage et PatchReady restent false. SV_Loaded/map transitoires pendant
map_restart peuvent arrêter le watcher avant publication : zéro événement write
ne prouve donc jamais absence de producteur.

La fermeture refuse de transformer une erreur de vacance/RCON en kill : quit
exige 30s vacant puis une lecture immédiate ; fallback terminé uniquement après
une seconde preuve 30s et identité retenue. UDP absent conserve processus et
réservation pour diagnostic. Le journal est retenu après sortie du process avec
hash pré/post ; restauration snapshot/vacance précède ExitLease. Échec de
restauration conserve la lease. La sortie exacte du processus détruit ses DR/VEH
mais reste distincte d'un ack cleanup natif. Tests purs exécutables :
`pwsh -NoProfile -File ops/agent-capacity/test_watch_runtime.ps1` ; aucune socket,
aucun jeu ni processus lancé par ces fixtures. Runtime watcher reste à faire.

La revue croisée a trouvé un statut trompeur si ExitLease échoue après une
restauration réussie : Restored=true ne signifie pas réservation libérée.
LeaseReleased n'est désormais posé qu'après le retour réussi du helper ;
LeaseRetained reste true sur son exception. Injection pure de cette exception,
cas absent/libéré et suites parser/stop ont passé localement.

CI PR106 head4041d0d a dépassé l'ancien timeout Java 30s même après sa ligne
PASS : cette ligne ne remplace pas un exit0. Le test pur
`test_decompile_owner_ranges.py` borne maintenant toute invocation source-file
Java (compilation/JVM inclus) à 90s et imprime le temps réel. Aucun timeout ni
code d'échec n'est ignoré. Test local JDK21 épinglé : exit0, 0.734s ; la nouvelle
CI reste le témoin de validation sur son propre runner.
