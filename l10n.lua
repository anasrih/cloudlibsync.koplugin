--[[--
Traduction minimale et autonome pour ce plugin.

Le système gettext central de KOReader (domaine "koreader", dossier l10n/ à
la racine de l'app) n'est pas conçu pour qu'un plugin tiers y greffe ses
propres fichiers .po/.mo de façon fiable — ça dépend de sa structure interne,
qui peut changer, et rien ne garantit qu'un plugin externe soit pris en
compte par le chargeur de traductions central.

À la place : un dictionnaire anglais → français embarqué ici, activé selon
la langue courante de KOReader (require("gettext").current_lang). Repli sur
l'anglais (texte source) si la langue n'est ni français ni reconnue, ou si
une chaîne n'a pas encore de traduction.

Pour ajouter une langue : dupliquer le bloc "fr" ci-dessous avec le code de
langue voulu (ex. "es"), traduire les valeurs, garder les clés (l'anglais)
identiques à ce qui apparaît dans le code.
--]]--

local Gettext = require("gettext")

local translations = {
    fr = {
        ["Configure the WebDAV server and local folder first."] = "Configure d'abord le serveur et le dossier local.",
        ["Server: %1"] = "Serveur : %1",
        ["Configure WebDAV server…"] = "Configurer le serveur WebDAV…",
        ["Local folder: %1"] = "Dossier local : %1",
        ["Choose local folder to sync…"] = "Choisir le dossier local à synchroniser…",
        ["Sync direction"] = "Sens de synchronisation",
        ["Bidirectional (recommended)"] = "Bidirectionnel (recommandé)",
        ["Local → Cloud only (upload)"] = "Local → Cloud uniquement (envoi)",
        ["Cloud → Local only (download)"] = "Cloud → Local uniquement (réception)",
        ["Allow sync to delete books"] = "Autoriser la synchro à supprimer des livres",
        ["Automatic sync triggers"] = "Déclencheurs de synchro automatique",
        ["On startup"] = "Au démarrage",
        ["On sleep"] = "À la mise en veille",
        ["On wake"] = "Au réveil",
        ["On closing a book"] = "À la fermeture d'un livre",
        ["Sync now"] = "Synchroniser maintenant",
        ["Last sync: %1"] = "Dernière synchro : %1",
        ["Never synced"] = "Jamais synchronisé",
        ["Sync log"] = "Journal des synchros",
        ["No syncs recorded yet."] = "Aucune synchronisation enregistrée pour l'instant.",
        ["Server URL (e.g. https://webdav.example.com/)"] = "URL du serveur (ex : https://webdav.exemple.com/)",
        ["Remote folder (e.g. Books)"] = "Dossier distant (ex : Livres)",
        ["Username"] = "Utilisateur",
        ["Password"] = "Mot de passe",
        ["Cancel"] = "Annuler",
        ["Save"] = "Enregistrer",
        ["WebDAV server"] = "Serveur WebDAV",
        ["Syncing…"] = "Synchronisation en cours…",
        ["Sync failed. Check the log (crash.log)."] = "Échec de la synchronisation. Voir le journal (crash.log).",
        ["No network — sync skipped."] = "Pas de réseau — synchro ignorée.",
        ["No network after %1s — sync abandoned."] = "Pas de réseau après %1s — synchro abandonnée.",
        ["Internal error: "] = "Erreur interne : ",
        ["retrying in 15s"] = "nouvelle tentative dans 15s",
        -- Sync trigger labels, shown in the sync log
        ["Startup"] = "Démarrage",
        ["Sleep"] = "Veille",
        ["Wake"] = "Réveil",
        ["Book closed"] = "Fermeture livre",
        ["Network reconnect"] = "Reconnexion réseau",
        ["Manual"] = "Manuel",
        -- Sync engine summaries (syncengine.lua)
        ["Incomplete scan (network or storage unavailable) — sync cancelled for safety"] = "Scan incomplet (réseau ou stockage indisponible) — synchro annulée par sécurité",
        ["↑%d uploaded, ↓%d downloaded, %d local deletions, %d remote deletions, %d conflicts"] = "↑%d envoyés, ↓%d reçus, %d suppr. locales, %d suppr. distantes, %d conflits",
        [" (%d file(s) too large, skipped)"] = " (%d fichier(s) trop volumineux ignoré(s))",
    },
}

local function currentLangCode()
    local lang = Gettext.current_lang or "en"
    return lang:match("^(%a%a)") or "en"
end

local function _(s)
    local dict = translations[currentLangCode()]
    if dict and dict[s] then return dict[s] end
    return s -- repli : texte source (anglais)
end

return _
