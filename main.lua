local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local PathChooser = require("ui/widget/pathchooser")
local _ = require("l10n")
local T = require("ffi/util").template
local logger = require("logger")

local WebDavApi = require("webdavapi")
local SyncEngine = require("syncengine")

local CloudLibSync = WidgetContainer:extend{
    name = "cloudlibsync",
    is_doc_only = false,
}

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/cloudlibsync.lua"

function CloudLibSync:init()
    self.settings = LuaSettings:open(SETTINGS_FILE)
    self.ui.menu:registerToMainMenu(self)
    self:tryStartupSync()
end

function CloudLibSync:onDispatcherRegisterActions()
    -- reserved if you want to add a keyboard shortcut/gesture later
end

function CloudLibSync:addToMainMenu(menu_items)
    menu_items.cloud_lib_sync = {
        text = "Cloud Lib Sync", -- plugin name, not translated
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    local url = self.settings:readSetting("url")
                    return url and T(_("Server: %1"), url) or _("Configure WebDAV server…")
                end,
                keep_menu_open = true,
                callback = function() self:showServerDialog() end,
            },
            {
                text_func = function()
                    local d = self.settings:readSetting("local_dir")
                    return d and T(_("Local folder: %1"), d) or _("Choose local folder to sync…")
                end,
                keep_menu_open = true,
                callback = function() self:chooseLocalDir() end,
            },
            {
                text = _("Sync direction"),
                sub_item_table = {
                    {
                        text = _("Bidirectional (recommended)"),
                        checked_func = function() return self:getDirection() == "both" end,
                        callback = function() self:setDirection("both") end,
                    },
                    {
                        text = _("Local → Cloud only (upload)"),
                        checked_func = function() return self:getDirection() == "upload" end,
                        callback = function() self:setDirection("upload") end,
                    },
                    {
                        text = _("Cloud → Local only (download)"),
                        checked_func = function() return self:getDirection() == "download" end,
                        callback = function() self:setDirection("download") end,
                    },
                },
            },
            {
                text = _("Allow sync to delete books"),
                checked_func = function() return self.settings:isTrue("allow_delete") end,
                callback = function()
                    self.settings:saveSetting("allow_delete", not self.settings:isTrue("allow_delete"))
                    self.settings:flush()
                end,
            },
            {
                text = _("Automatic sync triggers"),
                sub_item_table = {
                    {
                        text = _("On startup"),
                        checked_func = function() return self:isTriggerEnabled("startup") end,
                        callback = function() self:toggleTrigger("startup") end,
                    },
                    {
                        text = _("On sleep"),
                        checked_func = function() return self:isTriggerEnabled("suspend") end,
                        callback = function() self:toggleTrigger("suspend") end,
                    },
                    {
                        text = _("On wake"),
                        checked_func = function() return self:isTriggerEnabled("resume") end,
                        callback = function() self:toggleTrigger("resume") end,
                    },
                    {
                        text = _("On closing a book"),
                        checked_func = function() return self:isTriggerEnabled("close_document") end,
                        callback = function() self:toggleTrigger("close_document") end,
                    },
                },
            },
            {
                text = _("Sync now"),
                keep_menu_open = true,
                callback = function() self:runSync() end,
            },
            {
                text_func = function()
                    local t = self.settings:readSetting("last_sync")
                    return t and T(_("Last sync: %1"), t) or _("Never synced")
                end,
                enabled_func = function() return false end,
            },
            {
                text = _("Sync log"),
                keep_menu_open = true,
                callback = function() self:showSyncLog() end,
            },
        },
    }
end

-- Each of the 4 automatic-sync triggers (startup, suspend, resume,
-- close_document) has its own independent on/off setting, enabled by
-- default (unset == enabled) so a fresh install has everything on.
function CloudLibSync:isTriggerEnabled(key)
    local v = self.settings:readSetting("auto_sync_" .. key)
    if v == nil then return true end
    return v == true
end

function CloudLibSync:toggleTrigger(key)
    self.settings:saveSetting("auto_sync_" .. key, not self:isTriggerEnabled(key))
    self.settings:flush()
end

function CloudLibSync:getDirection()
    return self.settings:readSetting("direction") or "both"
end

function CloudLibSync:setDirection(dir)
    self.settings:saveSetting("direction", dir)
    self.settings:flush()
end

local SYNC_LOG_MAX_ENTRIES = 30

-- Internal trigger keys are stable English identifiers (never translated,
-- never shown as-is); triggerLabel() below maps them to a translated
-- display string, resolved fresh each time so a language change mid-session
-- (rare, but harmless to support) is reflected immediately.
local function triggerLabel(key)
    local labels = {
        startup = _("Startup"),
        suspend = _("Sleep"),
        resume = _("Wake"),
        close_document = _("Book closed"),
        network_reconnect = _("Network reconnect"),
        manual = _("Manual"),
    }
    return labels[key] or key or "?"
end

-- Sync log: keeps the last N entries (trigger + result), most recent first.
-- Viewable from the menu — handy to see what triggered what without having
-- to dig through crash.log.
function CloudLibSync:logSyncEvent(trigger, message)
    local log = self.settings:readSetting("sync_log") or {}
    table.insert(log, 1, { ts = os.time(), trigger = trigger or "manual", message = message })
    while #log > SYNC_LOG_MAX_ENTRIES do table.remove(log) end
    self.settings:saveSetting("sync_log", log)
    self.settings:flush()
end

function CloudLibSync:showSyncLog()
    local log = self.settings:readSetting("sync_log") or {}
    local lines = {}
    if #log == 0 then
        table.insert(lines, _("No syncs recorded yet."))
    else
        for _, entry in ipairs(log) do
            table.insert(lines, os.date("%Y-%m-%d %H:%M:%S", entry.ts)
                .. "  [" .. triggerLabel(entry.trigger) .. "]\n" .. entry.message)
        end
    end
    UIManager:show(TextViewer:new{
        title = _("Sync log"),
        text = table.concat(lines, "\n\n"),
    })
end

function CloudLibSync:chooseLocalDir()
    local chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        path = self.settings:readSetting("local_dir") or DataStorage:getDataDir(),
        onConfirm = function(path)
            self.settings:saveSetting("local_dir", path)
            self.settings:flush()
        end,
    }
    UIManager:show(chooser)
end

function CloudLibSync:showServerDialog()
    local s = self.settings
    local dialog
    dialog = MultiInputDialog:new{
        title = _("WebDAV server"),
        fields = {
            { hint = _("Server URL (e.g. https://webdav.example.com/)"), text = s:readSetting("url") or "" },
            { hint = _("Remote folder (e.g. Books)"), text = s:readSetting("remote_dir") or "" },
            { hint = _("Username"), text = s:readSetting("user") or "" },
            { hint = _("Password"), text_type = "password", text = s:readSetting("pass") or "" },
        },
        buttons = {
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                {
                    text = _("Save"),
                    callback = function()
                        local fields = dialog:getFields()
                        s:saveSetting("url", fields[1])
                        s:saveSetting("remote_dir", fields[2]:gsub("^/+", ""):gsub("/+$", ""))
                        s:saveSetting("user", fields[3])
                        s:saveSetting("pass", fields[4])
                        s:flush()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- True if a usable network is available right now. In silent (auto-sync)
-- mode, we don't try to force wifi on: we just cancel this cycle.
local function hasNetwork()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr then return true end -- unknown API -> try anyway
    if NetworkMgr.isConnected then
        return NetworkMgr:isConnected()
    end
    return true
end

-- silent = true for an automatic trigger (wake / closing a book / network
-- reconnect): no "in progress" dialog, no blocking error popup, just the log.
-- retries_left (silent only): how many more attempts are allowed if the scan
-- fails for network reasons (e.g. wifi reported ready too early after a
-- wake — observed in practice).
-- trigger: internal English key identifying the origin (shown, translated,
-- in the sync log): "startup", "suspend", "resume", "close_document",
-- "network_reconnect", "manual".
local AUTO_SYNC_RETRY_DELAY_S = 15
local AUTO_SYNC_MAX_RETRIES = 2

function CloudLibSync:runSync(silent, retries_left, trigger)
    trigger = trigger or "manual"
    local s = self.settings
    local url = s:readSetting("url")
    local local_dir = s:readSetting("local_dir")
    if not url or not local_dir then
        if not silent then
            UIManager:show(InfoMessage:new{ text = _("Configure the WebDAV server and local folder first.") })
        end
        return
    end
    if silent and not hasNetwork() then
        if (retries_left or 0) > 0 then
            logger.info("CloudLibSync: no network, retrying in", AUTO_SYNC_RETRY_DELAY_S, "s (", retries_left, "left)")
            UIManager:scheduleIn(AUTO_SYNC_RETRY_DELAY_S, function()
                self:runSync(true, retries_left - 1, trigger)
            end)
        else
            logger.info("CloudLibSync: auto-sync skipped, no network")
            self:logSyncEvent(trigger, _("No network — sync skipped."))
        end
        return
    end

    local webdav = WebDavApi.new{
        url = url,
        user = s:readSetting("user"),
        pass = s:readSetting("pass"),
    }
    local engine = SyncEngine.new{
        webdav = webdav,
        local_dir = local_dir:gsub("/+$", ""),
        remote_dir = (s:readSetting("remote_dir") or ""):gsub("/+$", ""),
        direction = self:getDirection(),
        allow_delete = s:isTrue("allow_delete"),
        known_bad = s:readSetting("oversized_paths") or {},
        bypass_known_bad = not silent, -- manual sync retries everything
    }

    local info
    if not silent then
        info = InfoMessage:new{ text = _("Syncing…") }
        UIManager:show(info)
        UIManager:forceRePaint()
    end

    local snapshot = s:readSetting("snapshot") or { local_ = {}, remote_ = {} }
    local ok, new_snapshot_or_err, summary, new_bad, aborted = pcall(function()
        return engine:run(snapshot)
    end)

    if info then UIManager:close(info) end

    if not ok then
        logger.warn("CloudLibSync: sync failed:", new_snapshot_or_err)
        self:logSyncEvent(trigger, _("Internal error: ") .. tostring(new_snapshot_or_err))
        if not silent then
            UIManager:show(InfoMessage:new{ text = _("Sync failed. Check the log (crash.log).") })
        end
        return
    end

    if aborted then
        -- Nothing was compared: don't touch any persisted setting (snapshot,
        -- oversized files, last sync date), so we don't throw off other
        -- triggers' cooldown or lose the memory of files already known to
        -- be too large.
        logger.info("CloudLibSync:", summary)
        local will_retry = silent and (retries_left or 0) > 0
        self:logSyncEvent(trigger, summary .. (will_retry and (" — " .. _("retrying in 15s")) or ""))
        if will_retry then
            logger.info("CloudLibSync: retrying in", AUTO_SYNC_RETRY_DELAY_S, "s (", retries_left, "left)")
            UIManager:scheduleIn(AUTO_SYNC_RETRY_DELAY_S, function()
                self:runSync(true, retries_left - 1, trigger)
            end)
        elseif not silent then
            UIManager:show(InfoMessage:new{ text = summary, timeout = 5 })
        end
        return
    end

    local new_snapshot, sync_summary = new_snapshot_or_err, summary
    s:saveSetting("snapshot", new_snapshot)
    s:saveSetting("oversized_paths", new_bad or {})
    s:saveSetting("last_sync", os.date("%Y-%m-%d %H:%M"))
    s:saveSetting("last_sync_ts", os.time())
    s:flush()

    logger.info("CloudLibSync:", sync_summary)
    self:logSyncEvent(trigger, sync_summary)
    if not silent then
        UIManager:show(InfoMessage:new{ text = sync_summary, timeout = 5 })
    end
end

-- Before sleep: safety net to push a local addition (direct USB transfer on
-- the device) made right before turning the screen off, without having gone
-- through "close a book" (e.g. USB copy without ever opening the file).
function CloudLibSync:onSuspend()
    self.pending_auto_sync = false -- cancel any pending reconnect wait
    if self:isTriggerEnabled("suspend") then
        self:runSync(true, AUTO_SYNC_MAX_RETRIES, "suspend")
    end
end

-- On wake: wifi isn't necessarily reconnected yet. If it's already fine, we
-- sync (after a short grace delay, see below). Otherwise we poll
-- periodically (rather than relying only on the onNetworkConnected event,
-- which isn't necessarily broadcast reliably depending on firmware/jailbreak)
-- up to a safety timeout, so we don't wait forever if wifi never comes back
-- (airplane mode, dead zone…).
local AUTO_SYNC_TIMEOUT_S = 60
local AUTO_SYNC_POLL_INTERVAL_S = 5
-- No auto resync if the last one was less than 2 min ago (avoids
-- re-triggering a full scan on every quick back-and-forth between books).
local AUTO_SYNC_MIN_INTERVAL_S = 120
-- "Wifi restored" can be announced before the network stack is actually
-- usable (observed in practice: a burst of "Network is unreachable" less
-- than a second after the announcement) — a short grace delay is applied
-- before syncing once the network is detected as available.
local NETWORK_GRACE_DELAY_S = 3

function CloudLibSync:isAutoSyncOnCooldown()
    local last = self.settings:readSetting("last_sync_ts")
    return last ~= nil and (os.time() - last) < AUTO_SYNC_MIN_INTERVAL_S
end

function CloudLibSync:scheduleSyncSoon(trigger)
    UIManager:scheduleIn(NETWORK_GRACE_DELAY_S, function() self:runSync(true, AUTO_SYNC_MAX_RETRIES, trigger) end)
end

function CloudLibSync:pollForNetworkAndSync(elapsed_s, trigger)
    if not self.pending_auto_sync then return end -- already handled in the meantime
    if not self:isTriggerEnabled(trigger) then
        self.pending_auto_sync = false -- disabled in the meantime, bail out cleanly
        return
    end
    if hasNetwork() then
        self.pending_auto_sync = false
        self:scheduleSyncSoon(trigger)
        return
    end
    if elapsed_s >= AUTO_SYNC_TIMEOUT_S then
        self.pending_auto_sync = false
        logger.info("CloudLibSync: auto-sync abandoned, no network after", AUTO_SYNC_TIMEOUT_S, "s")
        self:logSyncEvent(trigger, T(_("No network after %1s — sync abandoned."), AUTO_SYNC_TIMEOUT_S))
        return
    end
    UIManager:scheduleIn(AUTO_SYNC_POLL_INTERVAL_S, function()
        self:pollForNetworkAndSync(elapsed_s + AUTO_SYNC_POLL_INTERVAL_S, trigger)
    end)
end

-- Used by onResume and tryStartupSync: sync right away (after a grace
-- delay) if the network is already there, otherwise wait/poll.
function CloudLibSync:attemptAutoSync(trigger)
    if hasNetwork() then
        self:scheduleSyncSoon(trigger)
        return
    end
    self.pending_auto_sync = true
    self:pollForNetworkAndSync(0, trigger)
end

function CloudLibSync:onResume()
    if not self:isTriggerEnabled("resume") then return end
    self:attemptAutoSync("resume")
end

-- Broadcast by NetworkMgr as soon as the connection is up — fast path in
-- addition to the polling above, if the event does arrive.
function CloudLibSync:onNetworkConnected()
    if self.pending_auto_sync then
        self.pending_auto_sync = false
        self:scheduleSyncSoon("network_reconnect")
    end
end

-- When closing a book (back to the file manager): a good time to resync,
-- the device is awake so wifi should normally be available. Only fires if a
-- book was actually opened then closed — a plain USB file copy doesn't
-- trigger this event (that's what the onSuspend safety net above is for).
-- The cooldown avoids resyncing on every close if you go through several
-- books quickly.
function CloudLibSync:onCloseDocument()
    if not self:isTriggerEnabled("close_document") then return end
    if self:isAutoSyncOnCooldown() then return end
    self:runSync(true, AUTO_SYNC_MAX_RETRIES, "close_document")
end

-- On KOReader startup: covers the case where the device never went through
-- a real sleep before (full restart, relaunch after a crash) — in those
-- cases, neither onResume nor onSuspend fired. This hook can run more than
-- once (the plugin is instantiated both for the file manager and for each
-- book opened in the reader), hence the same cooldown as onCloseDocument to
-- avoid redundant syncs.
function CloudLibSync:tryStartupSync()
    if not self:isTriggerEnabled("startup") then return end
    if self:isAutoSyncOnCooldown() then return end
    self:attemptAutoSync("startup")
end

return CloudLibSync
