-- Minimal test harness: runs the plugin's pure-logic modules (syncengine,
-- webdavapi helpers) OUTSIDE KOReader.
--
-- Requirements: Lua 5.1 or LuaJIT (same semantics as KOReader) + luafilesystem
--   Debian/Ubuntu: sudo apt install lua5.1 lua-filesystem
--   Any OS:        luarocks --lua-version 5.1 install luafilesystem
--
-- What is stubbed: logger, gettext. What is real: lfs, plugin code.
-- What is NOT covered: anything touching KOReader widgets (menus, dialogs,
-- UIManager, NetworkMgr) -> verify those on a device.

local H = {}

local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
package.path = root .. "/?.lua;" .. package.path

H.logs = {}
package.preload["logger"] = function()
    local l = {}
    for _, lvl in ipairs({ "info", "warn", "err", "dbg" }) do
        l[lvl] = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            H.logs[#H.logs + 1] = lvl .. ": " .. table.concat(parts, " ")
        end
    end
    return l
end
package.preload["gettext"] = function()
    return setmetatable({ current_lang = "en" }, { __call = function(_, s) return s end })
end
package.preload["libs/libkoreader-lfs"] = function() return require("lfs") end

local lfs = require("lfs")
H.lfs = lfs

-- ---------- tiny test framework ----------
local tests, bugs = {}, {}
function H.test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
-- Known bug: expected to FAIL today. When it starts passing, move it to H.test.
function H.bug(name, fn) bugs[#bugs + 1] = { name = name, fn = fn } end

function H.eq(a, b, msg)
    if a ~= b then
        error((msg or "values differ") .. ": expected <" .. tostring(b) .. ">, got <" .. tostring(a) .. ">", 2)
    end
end
function H.truthy(v, msg) if not v then error(msg or "expected truthy", 2) end end
function H.falsy(v, msg) if v then error(msg or "expected falsy", 2) end end

function H.run()
    local failed = 0
    for _, t in ipairs(tests) do
        H.logs = {}
        local ok, err = pcall(t.fn)
        if ok then print("  ok      " .. t.name)
        else failed = failed + 1; print("  FAIL    " .. t.name .. "\n          " .. tostring(err)) end
    end
    for _, t in ipairs(bugs) do
        H.logs = {}
        local ok = pcall(t.fn)
        if ok then print("  FIXED?  " .. t.name .. "  (passes now: move it to H.test)")
        else print("  KNOWN   " .. t.name .. "  (known bug, still failing)") end
    end
    print(string.format("%d tests, %d failed, %d known bug(s) tracked", #tests, failed, #bugs))
    os.exit(failed == 0 and 0 or 1)
end

-- ---------- filesystem helpers ----------
local function mkdirp(path)
    if lfs.attributes(path, "mode") then return end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then mkdirp(parent) end
    lfs.mkdir(path)
end
H.mkdirp = mkdirp

function H.tmpdir()
    local p = os.tmpname(); os.remove(p); lfs.mkdir(p)
    return p
end
function H.rmtree(p)
    assert(p:match("^/tmp/"), "refusing to rm outside /tmp")
    os.execute("rm -rf '" .. p .. "'")
end
function H.write(path, content)
    local parent = path:match("^(.*)/[^/]+$")
    if parent then mkdirp(parent) end
    local f = assert(io.open(path, "wb")); f:write(content); f:close()
end
function H.read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local c = f:read("*a"); f:close(); return c
end
function H.exists(path) return lfs.attributes(path, "mode") ~= nil end

-- ---------- fake WebDAV server (in memory) ----------
-- files[remote_rel_path] = content. Records every call in .calls.
local Fake = {}; Fake.__index = Fake
function H.FakeWebDav()
    return setmetatable({ files = {}, calls = {}, fail_list = false, reject_413 = {}, fail_put = {}, fail_get = {} }, Fake)
end
function Fake:count(prefix)
    local n = 0
    for _, c in ipairs(self.calls) do if c:sub(1, #prefix) == prefix then n = n + 1 end end
    return n
end
function Fake:listFolder(rel)
    self.calls[#self.calls + 1] = "list:" .. tostring(rel)
    if self.fail_list then return nil, "Network is unreachable" end
    local base = (tostring(rel):gsub("/+$", ""))
    local prefix = (base == "") and "" or (base .. "/")
    local seen, out = {}, {}
    for path, content in pairs(self.files) do
        if path:sub(1, #prefix) == prefix then
            local rest = path:sub(#prefix + 1)
            local first, tail = rest:match("^([^/]+)(.*)$")
            if first and not seen[first] then
                seen[first] = true
                out[#out + 1] = { name = first, is_dir = (tail ~= ""), size = (tail == "") and #content or nil }
            end
        end
    end
    return out
end
function Fake:uploadFile(local_path, remote_path)
    self.calls[#self.calls + 1] = "put:" .. remote_path
    local name = remote_path:match("([^/]+)$")
    if self.reject_413[name] then return false, 413 end
    if self.fail_put[name] then return false, "Network is unreachable" end
    local c = H.read(local_path)
    if not c then return false, "local file missing" end
    self.files[remote_path] = c
    return true, 201
end
function Fake:downloadFile(remote_path, local_path)
    self.calls[#self.calls + 1] = "get:" .. remote_path
    local name = remote_path:match("([^/]+)$")
    if self.fail_get[name] then return false, "Network is unreachable" end
    local c = self.files[remote_path]
    if not c then return false, 404 end
    H.write(local_path, c)
    return true
end
function Fake:deleteFile(remote_path)
    self.calls[#self.calls + 1] = "del:" .. remote_path
    self.files[remote_path] = nil
    return true, 204
end

return H
