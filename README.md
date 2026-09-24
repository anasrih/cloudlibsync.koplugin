# Cloud Lib Sync

A KOReader plugin that syncs a local folder with a remote folder on a
WebDAV server (conceptually tested against Apache mod_dav / Nextcloud /
`openmediavault-webdav`).

## Installation

1. Copy the whole `cloudlibsync.koplugin/` folder into `koreader/plugins/`
   on each device (jailbroken Kindle, Android…).
   - Kindle: via USB, into `koreader/plugins/cloudlibsync.koplugin/`
   - Android: `/sdcard/koreader/plugins/cloudlibsync.koplugin/` (or the
     equivalent path depending on where KOReader is installed)
2. Restart KOReader.
3. Main menu → **Tools** → **Cloud Lib Sync**.
4. Configure:
   - **Server URL**: your WebDAV endpoint (e.g. one exposed via OMV)
   - **Remote folder**: relative path on the server (e.g. `Books`)
   - **Username / password**
   - **Local folder** to sync (your KOReader library)
5. Choose the **sync direction** and whether **deletions** should be
   propagated.
6. **Sync now**.

Repeat the install + config (same URL/remote folder) on each device: a book
added on one will show up on the others on the next sync.

## How it works

- `webdavapi.lua`: minimal WebDAV client (PROPFIND/GET/PUT/DELETE/MKCOL)
  built on LuaSocket/LuaSec, without depending on the internal
  `cloudstorage` plugin.
- `syncengine.lua`: compares the current local/remote state to a "last
  known state" (snapshot, saved in the plugin's settings) to tell an
  addition from a deletion and decide which side to propagate a change to.
- `main.lua`: menu, configuration dialogs, triggering, and automatic sync.
- `l10n.lua`: translation. See "Internationalization" below.

### Internationalization

Every user-facing string has its source text in English (`_("...")`),
translated into French through a small dictionary in `l10n.lua`, selected
based on `require("gettext").current_lang`. This is *not* KOReader's
central gettext system (domain `koreader`, `l10n/` folder at the app
root): that system is built for the app itself, not for a third-party
plugin to hook its own translations into reliably across versions. A
self-contained dictionary avoids that fragile dependency, at the cost of
maintaining translations by hand.

To add a language: duplicate the `fr = { ... }` block in `l10n.lua` with
the language code you want (e.g. `es`), translate the values, and keep the
keys (the English text) identical to what appears in the code. With no
entry in the dictionary for the active language, the English source text
is shown (automatic fallback, never a missing string).

Logs (`logger.info`/`logger.warn`) always stay in English, even with the
UI in French — standard convention, useful for support or when sharing
`crash.log`.

### Automatic sync triggers

Each of the 4 triggers below has its own independent on/off setting in
*Menu → Cloud Lib Sync → Automatic sync triggers*, all **enabled by
default** on a fresh install:

- **On startup** (`init`): covers the case where the device never went
  through a real sleep cycle before (full restart, relaunch after a
  crash) — without this hook, neither `onResume` nor `onSuspend` would
  have fired. Guarded by the same 2-minute cooldown as `onCloseDocument`,
  since this hook can run more than once (the plugin is instantiated both
  for the file manager and for each book opened).
- **On sleep** (`onSuspend`): silent sync right before the device sleeps —
  a safety net to push a local addition (direct USB transfer onto the
  device) made without ever opening the added book.
- **On wake** (`onResume`): if the network is already up, sync
  immediately. Otherwise, a "pending" flag is set and the plugin **polls
  the connection every 5s for up to 60s** (rather than relying solely on
  the `onNetworkConnected` event, which isn't guaranteed to be reliable
  across firmwares/jailbreaks); `onNetworkConnected` is still listened to
  as a fast path in case the event does arrive.
- **On closing a book** (`onCloseDocument`): when you close a book and
  return to the file manager — only fires if a book was **actually opened
  then closed** in KOReader; a plain USB file copy with no book ever
  opened doesn't trigger this event (hence the `onSuspend` safety net
  above). Guarded by a 2-minute cooldown to avoid a full scan on every
  quick back-and-forth between books.
- If **every** trigger is disabled, automatic sync is effectively off —
  manual sync ("Sync now") is always available regardless.
- Automatic syncs are silent (no popup); only manual sync shows messages.

### Sync log

*Menu → Cloud Lib Sync → Sync log* shows the last 30 syncs (trigger +
result, most recent first): startup, sleep, wake, book closed, network
reconnect, manual. Useful for troubleshooting without digging through
`crash.log`. Persisted in the plugin's settings, no time limit (just a cap
on entry count).

## Known limitations / things to check on your setup

- **No periodic background sync** while the device stays awake: only on
  startup/sleep/wake/book-close and on "Sync now". Easy to add with a
  self-rescheduling `UIManager:scheduleIn()` if you want a fixed interval
  on top of that.
- **No file size limit in the plugin itself** — transfers are streamed
  disk to disk, nothing is loaded into memory. Network timeouts are
  tuned accordingly: 10s/30s for metadata operations (listing, folder
  creation), 30s/600s for file transfers (GET/PUT), so a large epub or
  audiobook has time to go through on slow wifi. Still subject to your
  server's own limits (e.g. nginx's `client_max_body_size` if you're
  behind a reverse proxy).
- **Files rejected by the server (413 Request Entity Too Large)** are
  remembered (path + size, in the plugin's settings) and **skipped on
  subsequent automatic syncs**, to avoid losing time on them again on
  every sleep/wake cycle. A manual "Sync now" always retries everything,
  including these files (useful after raising `client_max_body_size` on
  the server, for instance).
- **Incomplete scan = sync cancelled, never treated as "everything is
  gone"**: if the local or remote listing fails partway through (network
  dropped during the scan, local storage momentarily inaccessible…), the
  sync cancels entirely rather than comparing a partial state — otherwise
  real files could look "deleted" on the failing side and that false
  deletion could get propagated to the other side if "allow deletions" is
  on. In that case, no setting is touched (snapshot, oversized-files list,
  last-sync date all stay as they were), so other triggers' cooldown isn't
  thrown off.
- **Automatic retry after an aborted scan (network)**: for an automatic
  (silent) sync, up to 2 more attempts 15s apart if the scan fails for
  network reasons, before giving up until the next natural trigger.
  Manual sync ("Sync now") doesn't auto-retry — the failure is just shown,
  up to you to tap the button again.
- **"Wifi announced ready" vs "network actually usable" race**: observed
  in practice — right after reconnecting, KOReader can announce wifi as
  restored a second before the network stack is actually functional
  (`Network is unreachable` on the first requests). A 3s grace delay is
  applied before any automatic sync triggered by a network detection, to
  reduce (not eliminate) this risk.
- **Sync is blocking**: `onSuspend`/`onResume`/`onCloseDocument` make a
  real synchronous network call, which delays sleep or the return to the
  file manager by that much while the sync isn't done. On slow wifi or
  with a lot of files to compare, this can be noticeable. No simple fix
  without running the sync in a KOReader coroutine — worth considering
  later if it becomes a daily annoyance.
- **PROPFIND XML parsing is tolerant but not a real parser**: if it
  returns no entries against your server, log the raw response (add a
  `logger.info(resp_body)` in `webdavapi.lua:listFolder`) and adjust the
  `gmatch` patterns.
- Change detection relies on **file size** (WebDAV timestamps aren't
  reliable across servers) — so two files of the same size but different
  content won't be detected as changed. Could be strengthened with a hash
  if needed.
- On a **conflict** (changed on both sides since the last sync), nothing
  is overwritten automatically — it's just logged. Up to you to decide if
  you want automatic merging (keep both, rename) later.
- `.sdr` folders (KOReader sidecar metadata: reading progress,
  annotations) are **excluded** from sync by default (`isIgnored` in
  `syncengine.lua`). If you also want to sync reading progress across
  devices, better to use KOReader's native "Reading statistics" → "Cloud
  sync" plugin, built for that (syncs `.sqlite3` files), rather than
  including `.sdr` here.

## License

MIT — see `LICENSE` (or add one before publishing if you haven't yet).

*[Version française du README : README.fr.md]*
