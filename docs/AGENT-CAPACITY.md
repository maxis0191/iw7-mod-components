# Capacité native : préparer un port cohérent vers 48 agents

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
