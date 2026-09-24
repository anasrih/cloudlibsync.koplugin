# Cloud Lib Sync

Plugin KOReader : synchronise un dossier local avec un dossier distant sur un
serveur WebDAV (testé conceptuellement contre Apache mod_dav / Nextcloud /
`openmediavault-webdav`).

## Installation

1. Copie tout le dossier `cloudlibsync.koplugin/` dans `koreader/plugins/`
   sur chaque appareil (Kindle jailbreaké, Android…).
   - Kindle : via USB dans `koreader/plugins/cloudlibsync.koplugin/`
   - Android : `/sdcard/koreader/plugins/cloudlibsync.koplugin/` (ou le
     chemin équivalent selon où KOReader est installé)
2. Redémarre KOReader.
3. Menu principal → **Outils** → **Cloud Lib Sync**.
4. Configure :
   - **URL du serveur** : ton endpoint WebDAV (ex. celui exposé via OMV)
   - **Dossier distant** : chemin relatif sur le serveur (ex. `Livres`)
   - **Utilisateur / mot de passe**
   - **Dossier local** à synchroniser (ta bibliothèque KOReader)
5. Choisis le **sens de synchro** et si les **suppressions** doivent se
   propager.
6. **Synchroniser maintenant**.

Répète l'installation + configuration (même URL/dossier distant) sur chaque
appareil : un livre ajouté sur l'un réapparaîtra sur les autres au prochain
sync.

## Fonctionnement

- `webdavapi.lua` : client WebDAV minimal (PROPFIND/GET/PUT/DELETE/MKCOL)
  basé sur LuaSocket/LuaSec, sans dépendre du plugin `cloudstorage` interne.
- `syncengine.lua` : compare l'état courant local/distant à un "dernier état
  connu" (snapshot, sauvegardé dans les réglages) pour distinguer un ajout
  d'une suppression et savoir de quel côté propager le changement.
- `main.lua` : menu, dialogues de configuration, déclenchement, et la
  synchro automatique.
- `l10n.lua` : traduction. Voir "Internationalisation" ci-dessous.

### Internationalisation

Toutes les chaînes visibles par l'utilisateur ont leur texte source en
anglais (`_("...")`), traduites en français via un petit dictionnaire dans
`l10n.lua`, activé selon `require("gettext").current_lang`. Ce n'est *pas*
le système gettext central de KOReader (domaine `koreader`, dossier `l10n/`
à la racine de l'app) : ce système est pensé pour l'app elle-même, pas pour
qu'un plugin tiers y greffe ses propres traductions de façon fiable d'une
version à l'autre. Un dictionnaire autonome évite cette dépendance fragile,
au prix de devoir maintenir les traductions à la main.

Pour ajouter une langue : dupliquer le bloc `fr = { ... }` dans `l10n.lua`
avec le code de langue voulu (ex. `es`), traduire les valeurs, garder les
clés (le texte anglais) identiques à ce qui apparaît dans le code. Sans
entrée dans le dictionnaire pour la langue active, le texte source anglais
s'affiche (repli automatique, jamais de chaîne manquante).

Les logs (`logger.info`/`logger.warn`) restent toujours en anglais, même
avec l'interface en français — convention standard, utile pour du support
ou en cas de partage de `crash.log`.

### Déclencheurs de synchro automatique

Chacun des 4 déclencheurs ci-dessous a son propre réglage indépendant dans
*Menu → Cloud Lib Sync → Déclencheurs de synchro automatique*, tous
**activés par défaut** à l'installation :

- **Au démarrage** (`init`) : couvre le cas où l'appareil n'est jamais
  passé par une vraie mise en veille avant (redémarrage complet, relance
  après un plantage) — sans ce hook, ni `onResume` ni `onSuspend` ne se
  seraient déclenchés. Protégé par le même cooldown de 2 minutes que
  `onCloseDocument`, car ce hook peut s'exécuter plusieurs fois (le plugin
  est instancié à la fois pour le gestionnaire de fichiers et pour chaque
  livre ouvert).
- **À la mise en veille** (`onSuspend`) : synchro silencieuse juste avant
  la veille — filet de sécurité pour pousser un ajout local (transfert USB
  direct sur l'appareil) fait sans jamais ouvrir le livre ajouté.
- **Au réveil** (`onResume`) : si le réseau est déjà là, synchro
  immédiate. Sinon, un drapeau "en attente" est armé et le plugin **sonde
  la connexion toutes les 5s pendant 60s** (plutôt que de dépendre
  uniquement de l'événement `onNetworkConnected`, qui n'est pas garanti
  fiable sur tous les firmwares/jailbreaks) ; `onNetworkConnected` reste
  écouté en plus comme raccourci si l'événement arrive bien.
- **À la fermeture d'un livre** (`onCloseDocument`) : quand tu fermes un
  livre et reviens au gestionnaire de fichiers — ne se déclenche que si un
  livre a été **réellement ouvert puis fermé** dans KOReader ; une simple
  copie de fichier par USB sans ouverture ne déclenche pas cet événement
  (d'où l'intérêt du filet `onSuspend` ci-dessus). Protégé par un cooldown
  de 2 minutes pour éviter un scan complet à chaque va-et-vient rapide
  entre plusieurs livres.
- Si **tous** les déclencheurs sont désactivés, la synchro automatique est
  effectivement coupée — la synchro manuelle ("Synchroniser maintenant")
  reste toujours disponible quel que soit leur état.
- Les synchros automatiques sont silencieuses (pas de popup), seule la
  synchro manuelle affiche des messages.

### Journal des synchros

*Menu → Cloud Lib Sync → Journal des synchros* affiche les 30 dernières
synchros (déclencheur + résultat, plus récent en premier) : démarrage,
veille, réveil, fermeture livre, reconnexion réseau, manuel. Utile pour
diagnostiquer sans aller fouiller `crash.log`. Persisté dans les réglages
du plugin, pas de limite de durée (juste de nombre d'entrées).

## Limites connues / points à vérifier chez toi

- **Pas de sync périodique en tâche de fond** pendant que l'appareil reste
  éveillé : seulement au démarrage/veille/réveil/fermeture de livre et sur
  "Synchroniser maintenant". Facile à ajouter avec `UIManager:scheduleIn()`
  qui se reprogramme lui-même si tu veux un intervalle fixe en plus.
- **Pas de limite de taille de fichier dans le plugin** — les transferts
  sont streamés disque à disque, rien n'est chargé en mémoire. Les délais
  réseau sont adaptés : 10s/30s pour les opérations de métadonnées
  (listing, création de dossier), 30s/600s pour les transferts de fichiers
  (GET/PUT), afin qu'un gros epub ou un audiobook sur wifi lent ait le
  temps de passer. Reste soumis aux limites de ton serveur (ex. la
  directive `client_max_body_size` de nginx si tu passes par un reverse
  proxy).
- **Fichiers rejetés par le serveur (413 Request Entity Too Large)** :
  mémorisés (taille + chemin, dans les réglages du plugin) et **ignorés
  lors des synchros automatiques suivantes**, pour éviter de reperdre du
  temps dessus à chaque veille/réveil. Un "Synchroniser maintenant" manuel
  retente toujours tout, y compris ces fichiers (utile après avoir
  augmenté `client_max_body_size` côté serveur, par exemple).
- **Scan incomplet = synchro annulée, jamais interprétée comme "tout a
  disparu"** : si le listing local ou distant échoue en cours de route
  (réseau coupé pendant le scan, stockage local temporairement
  inaccessible…), la synchro s'annule intégralement plutôt que de comparer
  un état partiel — sinon des fichiers bien réels pourraient être vus comme
  supprimés côté en échec, et propager cette fausse suppression de l'autre
  côté si "autoriser la suppression" est actif. Dans ce cas, aucun réglage
  n'est modifié (ni snapshot, ni liste des fichiers trop volumineux, ni
  date de dernière synchro), pour ne pas fausser les autres déclencheurs.
- **Retry automatique après un scan avorté (réseau)** : pour une synchro
  automatique (silencieuse), jusqu'à 2 nouvelles tentatives à 15s
  d'intervalle si le scan échoue pour cause réseau, avant d'abandonner
  jusqu'au prochain déclencheur naturel. La synchro manuelle
  ("Synchroniser maintenant") ne retente pas automatiquement — l'échec est
  juste affiché, à toi de retaper le bouton.
- **Course "wifi annoncé prêt" vs "réseau réellement utilisable"** :
  observé en pratique — juste après reconnexion, KOReader peut annoncer le
  wifi comme rétabli une seconde avant que la pile réseau soit vraiment
  fonctionnelle (`Network is unreachable` sur les premières requêtes). Un
  délai de grâce de 3s est appliqué avant toute synchro automatique
  déclenchée par une détection réseau, pour réduire (sans l'éliminer
  totalement) ce risque.
- **La synchro est bloquante** : `onSuspend`/`onResume`/`onCloseDocument`
  font un vrai appel réseau synchrone, ce qui retarde d'autant la mise en
  veille ou le retour au gestionnaire de fichiers tant que la synchro n'est
  pas terminée. Sur un wifi lent ou avec beaucoup de fichiers à comparer,
  ça peut se sentir. Pas de vrai correctif simple sans faire tourner la
  synchro dans une coroutine KOReader — envisageable plus tard si ça
  devient gênant au quotidien.
- Le **parsing XML du PROPFIND est tolérant mais pas un vrai parseur** :
  s'il ne remonte aucune entrée avec ton serveur, inspecte la réponse brute
  (ajoute un `logger.info(resp_body)` dans `webdavapi.lua:listFolder`) et
  ajuste les motifs `gmatch`.
- La détection de modification se base sur la **taille du fichier**
  (les timestamps WebDAV ne sont pas fiables d'un serveur à l'autre) —
  donc deux fichiers de même taille mais contenu différent ne seront pas
  détectés comme modifiés. À muscler avec un hash si besoin.
- En cas de **conflit** (modifié des deux côtés depuis le dernier sync),
  rien n'est écrasé automatiquement — c'est juste loggé. À toi de décider
  si tu veux un merge automatique (garder les deux, renommer) plus tard.
- Les dossiers `.sdr` (métadonnées KOReader : progression de lecture,
  annotations) sont **exclus** de la synchro par défaut (`isIgnored` dans
  `syncengine.lua`). Si tu veux aussi synchroniser la progression de
  lecture entre appareils, il vaut mieux utiliser le plugin natif
  "Statistiques de lecture" → "Cloud sync" de KOReader, prévu pour ça
  (sync des `.sqlite3`), plutôt que d'inclure les `.sdr` ici.

## Licence

MIT — voir `LICENSE` (ou à ajouter avant publication si ce n'est pas déjà
fait).

*[English version of the README: README.md]*
