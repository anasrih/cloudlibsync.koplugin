--[[--
Sync engine.

Principle (rsync/Unison-style, simplified): we keep in memory the "last
known state" (snapshot) on both sides after each successful sync. On the
next sync, we compare the current local state, the current remote state,
and that snapshot for each file:

  - not present anywhere before, appeared on one side -> an ADDITION -> copy
  - present on both sides before, changed on one side only -> UPDATE -> copy
  - present on both sides before, changed on both sides -> CONFLICT -> keep
    both (no automatic overwrite)
  - present before, gone from one side -> DELETION
      - if allow_delete = true  -> also delete on the other side
      - if allow_delete = false -> ignore (no deletion propagated)

The sync direction restricts which actions are allowed:
  "both"     : upload + download + deletions in both directions
  "upload"   : local -> cloud only (nothing is ever downloaded)
  "download" : cloud -> local only (nothing is ever uploaded)
--]]--

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("l10n")

local SyncEngine = {}
SyncEngine.__index = SyncEngine

function SyncEngine.new(o)
    local self = setmetatable({}, SyncEngine)
    self.webdav = o.webdav          -- WebDavApi instance
    self.local_dir = o.local_dir    -- absolute local path, no trailing "/"
    self.remote_dir = o.remote_dir  -- relative remote path, no trailing "/"
    self.direction = o.direction or "both" -- "both" | "upload" | "download"
    self.allow_delete = o.allow_delete or false
    self.progress_cb = o.progress_cb or function() end
    -- { [relative_path] = local_size_at_rejection_time } — files a previous
    -- upload attempt was rejected for (413 Request Entity Too Large) at that
    -- exact size. Not retried unless the local file's size has changed,
    -- to avoid losing several seconds again on every sync over a file
    -- already known to be too large. bypass_known_bad=true (manual sync)
    -- ignores this list and retries everything.
    self.known_bad = o.known_bad or {}
    self.bypass_known_bad = o.bypass_known_bad or false
    return self
end

local function isIgnored(name)
    if name == "." or name == ".." then return true end
    if name:sub(1, 1) == "." then return true end
    if name:match("%.sdr$") then return true end -- KOReader sidecar metadata
    return false
end

-- Recursive local scan -> { [relative_path] = { mtime=, size= } }
-- failed is a shared table { flag=bool }: if walking a folder fails
-- (inaccessible, device removed, etc.), we stop and report the failure
-- instead of continuing with a partial result — a silent partial result
-- would make real files look "deleted".
local function scanLocal(dir, prefix, out, failed)
    out = out or {}
    failed = failed or { flag = false }
    if failed.flag then return out, failed end
    prefix = prefix or ""
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then
        failed.flag = true
        return out, failed
    end
    for name in iter, dir_obj do
        if not isIgnored(name) then
            local full = dir .. "/" .. name
            local rel = (prefix == "") and name or (prefix .. "/" .. name)
            local attr = lfs.attributes(full)
            if attr then
                if attr.mode == "directory" then
                    scanLocal(full, rel, out, failed)
                else
                    out[rel] = { mtime = attr.modification, size = attr.size }
                end
            end
        end
    end
    return out, failed
end

-- Recursive remote scan via repeated PROPFIND Depth:1 -> { [relative_path] = {...} }
-- Same principle as scanLocal: a failed PROPFIND (network, server down) must
-- stop and report the failure, not return a partial result that would make
-- real remote files look "deleted".
local function scanRemote(webdav, remote_dir, prefix, out, failed)
    out = out or {}
    failed = failed or { flag = false }
    if failed.flag then return out, failed end
    prefix = prefix or ""
    local entries, err = webdav:listFolder((remote_dir .. "/" .. prefix):gsub("^/", ""))
    if not entries then
        logger.warn("CloudLibSync: PROPFIND failed on", prefix, err)
        failed.flag = true
        return out, failed
    end
    for _, e in ipairs(entries) do
        if not isIgnored(e.name) then
            local rel = (prefix == "") and e.name or (prefix .. "/" .. e.name)
            if e.is_dir then
                scanRemote(webdav, remote_dir, rel, out, failed)
            else
                out[rel] = { mtime = e.mtime, size = e.size }
            end
        end
    end
    return out, failed
end

-- true if mtime/size differ significantly (we tolerate some clock drift
-- between the device and the server).
local function changedSince(cur, ref)
    if not cur or not ref then return cur ~= ref end
    if cur.size and ref.size and cur.size ~= ref.size then return true end
    return false -- mostly rely on size: remote mtimes aren't very reliable
end

-- Upload a file, unless it's already known to have been rejected (413) at
-- this exact size and this isn't a manual sync. Feeds new_bad so the caller
-- persists the up-to-date list. Returns true if actually uploaded successfully.
function SyncEngine:tryUpload(rel, local_path, remote_path, l, new_bad)
    local known_size = self.known_bad[rel]
    if known_size and known_size == l.size and not self.bypass_known_bad then
        new_bad[rel] = known_size -- still too large at this size: don't retry
        return false
    end
    self.progress_cb("upload", rel)
    local ok, status = self.webdav:uploadFile(local_path, remote_path)
    if not ok and status == 413 then
        logger.warn("CloudLibSync: file too large for the server, skipping from now on:", rel)
        new_bad[rel] = l.size
    end
    return ok
end

-- snapshot = { local_ = {...}, remote_ = {...} } (state after the last sync)
-- Returns the new snapshot, a text summary, and the updated list of files
-- known to be too large (for the caller to persist), and true as a 4th
-- value if the sync was aborted before comparing anything.
function SyncEngine:run(snapshot)
    snapshot = snapshot or { local_ = {}, remote_ = {} }
    local cur_local, local_failed = scanLocal(self.local_dir, "")
    local cur_remote, remote_failed = scanRemote(self.webdav, self.remote_dir, "")

    if (local_failed and local_failed.flag) or (remote_failed and remote_failed.flag) then
        -- Incomplete scan (network dropped mid-way, local storage
        -- momentarily inaccessible…): cancel everything rather than compare
        -- a partial state, which would make real files look "deleted" and
        -- risk propagating that false deletion to the other side. Nothing
        -- is touched (neither snapshot nor the oversized-files list): the
        -- caller must ignore these return values and persist nothing;
        -- aborted=true signals that.
        logger.warn("CloudLibSync: local or remote scan incomplete, sync cancelled for safety")
        return snapshot, _("Incomplete scan (network or storage unavailable) — sync cancelled for safety"), {}, true
    end

    local all_paths = {}
    for p in pairs(cur_local) do all_paths[p] = true end
    for p in pairs(cur_remote) do all_paths[p] = true end
    for p in pairs(snapshot.local_) do all_paths[p] = true end
    for p in pairs(snapshot.remote_) do all_paths[p] = true end

    local uploaded, downloaded, deleted_local, deleted_remote, conflicts = 0, 0, 0, 0, 0
    local new_snapshot_local, new_snapshot_remote = {}, {}
    local new_bad = {}

    for rel in pairs(all_paths) do
        local l, r = cur_local[rel], cur_remote[rel]
        local sl, sr = snapshot.local_[rel], snapshot.remote_[rel]
        local local_path = self.local_dir .. "/" .. rel
        local remote_path = (self.remote_dir .. "/" .. rel):gsub("^/", "")

        if l and r then
            -- exists on both sides
            local l_changed = changedSince(l, sl)
            local r_changed = changedSince(r, sr)
            if l_changed and r_changed and sl and sr then
                conflicts = conflicts + 1
                logger.warn("CloudLibSync: conflict on", rel, "- both sides changed, no automatic action")
            elseif l_changed and self.direction ~= "download" then
                if self:tryUpload(rel, local_path, remote_path, l, new_bad) then uploaded = uploaded + 1 end
            elseif r_changed and self.direction ~= "upload" then
                self.progress_cb("download", rel)
                local ok = self.webdav:downloadFile(remote_path, local_path)
                if ok then downloaded = downloaded + 1 end
            end
            new_snapshot_local[rel] = l
            new_snapshot_remote[rel] = r

        elseif l and not r then
            if sr then
                -- existed remotely before, now gone: remote deletion detected
                if self.allow_delete and self.direction ~= "download" then
                    self.progress_cb("delete_local", rel)
                    os.remove(local_path)
                    deleted_local = deleted_local + 1
                    -- don't re-insert into the new snapshot: entry deleted
                else
                    -- delete nothing: "restore" on the remote side if the
                    -- direction allows it
                    if self.direction ~= "download" then
                        if self:tryUpload(rel, local_path, remote_path, l, new_bad) then uploaded = uploaded + 1 end
                    end
                    new_snapshot_local[rel] = l
                    new_snapshot_remote[rel] = l
                end
            else
                -- new local file
                if self.direction ~= "download" then
                    if self:tryUpload(rel, local_path, remote_path, l, new_bad) then uploaded = uploaded + 1 end
                    new_snapshot_local[rel] = l
                    new_snapshot_remote[rel] = l
                end
            end

        elseif r and not l then
            if sl then
                -- local deletion detected
                if self.allow_delete and self.direction ~= "upload" then
                    self.progress_cb("delete_remote", rel)
                    self.webdav:deleteFile(remote_path)
                    deleted_remote = deleted_remote + 1
                else
                    if self.direction ~= "upload" then
                        self.progress_cb("download", rel)
                        local ok = self.webdav:downloadFile(remote_path, local_path)
                        if ok then downloaded = downloaded + 1 end
                    end
                    new_snapshot_local[rel] = r
                    new_snapshot_remote[rel] = r
                end
            else
                -- new remote file
                if self.direction ~= "upload" then
                    self.progress_cb("download", rel)
                    local ok = self.webdav:downloadFile(remote_path, local_path)
                    if ok then downloaded = downloaded + 1 end
                    new_snapshot_local[rel] = r
                    new_snapshot_remote[rel] = r
                end
            end
        end
        -- if neither l nor r: gone from both sides a while ago, nothing to do
    end

    local summary = string.format(
        _("↑%d uploaded, ↓%d downloaded, %d local deletions, %d remote deletions, %d conflicts"),
        uploaded, downloaded, deleted_local, deleted_remote, conflicts)
    if next(new_bad) then
        local n = 0
        for _ in pairs(new_bad) do n = n + 1 end
        summary = summary .. string.format(_(" (%d file(s) too large, skipped)"), n)
    end

    return { local_ = new_snapshot_local, remote_ = new_snapshot_remote }, summary, new_bad
end

return SyncEngine
