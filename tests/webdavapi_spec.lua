package.path = ((arg and arg[0] or ""):match("^(.*)/[^/]+$") or ".") .. "/?.lua;" .. package.path
local H = require("harness")

-- webdavapi.lua requires LuaSocket/LuaSec, which are bundled with KOReader
-- but not necessarily installed here. Network modules are stubbed (no test
-- touches the network: _request is replaced below). socket.url is a verbatim
-- copy of LuaSocket's escape/unescape, so the encoding behaviour under test
-- is the one used on devices: escape() encodes every byte outside
-- [A-Za-z0-9_] with lowercase hex.
package.preload["socket.url"] = function()
    local M = {}
    function M.escape(s)
        return (string.gsub(s, "([^A-Za-z0-9_])", function(c)
            return string.format("%%%02x", string.byte(c))
        end))
    end
    function M.unescape(s)
        return (string.gsub(s, "%%(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
        end))
    end
    return M
end
for _, m in ipairs({ "socket.http", "ssl.https", "ltn12", "mime" }) do
    package.preload[m] = function() return {} end
end
package.preload["socketutil"] = function()
    return { LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
             set_timeout = function() end, reset_timeout = function() end }
end

local WebDavApi = require("webdavapi")
local SyncEngine = require("syncengine")

-- Encodes a path the way Nextcloud/SabreDAV does in PROPFIND hrefs:
-- uppercase hex, unreserved characters ("-", ".", "~") left as is.
local function serverEncode(path)
    return (path:gsub("[^%w%-._~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Builds an API whose PROPFIND is served from an in-memory tree.
-- tree[path relative to the WebDAV root] = "dir" | <file content>
-- base_path: path part of the configured URL (e.g. Nextcloud's
-- "/remote.php/dav/files/user/"). Requests on unknown paths get a 404,
-- like a real server.
local function fakeApi(tree, base_path, opts)
    opts = opts or {}
    local api = WebDavApi.new{ url = "https://cloud.example.com" .. base_path, user = "u", pass = "p" }
    api.requested = {}
    function api:_request(method, rel_path)
        rel_path = (rel_path or ""):gsub("^/+", ""):gsub("/+$", "")
        self.requested[#self.requested + 1] = rel_path
        if tree[rel_path] ~= "dir" then return false, 404 end
        local function entry(p, is_dir, content)
            local href = serverEncode(base_path .. p) .. (is_dir and "/" or "")
            if opts.full_url_href then href = "https://cloud.example.com" .. href end
            local rt = is_dir and "<d:resourcetype><d:collection/></d:resourcetype>" or "<d:resourcetype/>"
            local len = is_dir and "" or ("<d:getcontentlength>" .. #content .. "</d:getcontentlength>")
            return "<d:response><d:href>" .. href .. "</d:href><d:propstat><d:prop>" .. rt .. len
                .. "</d:prop></d:propstat></d:response>"
        end
        local parts = { '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">', entry(rel_path, true) }
        for p, v in pairs(tree) do
            local parent, name = p:match("^(.*)/([^/]+)$")
            if not parent then parent, name = "", p end
            if parent == rel_path and name ~= "" then
                parts[#parts + 1] = entry(p, v == "dir", v)
            end
        end
        parts[#parts + 1] = "</d:multistatus>"
        return true, 207, table.concat(parts)
    end
    return api
end

local function names(entries)
    local t = {}
    for _, e in ipairs(entries) do t[#t + 1] = e.name end
    table.sort(t)
    return table.concat(t, ",")
end

local NC = "/remote.php/dav/files/user/"

H.test("listFolder skips its own entry (plain name)", function()
    local api = fakeApi({ ["Books"] = "dir", ["Books/a.epub"] = "A" }, NC)
    H.eq(names(api:listFolder("Books")), "a.epub")
end)

for _, folder in ipairs({ "MY SERIES", "Éléments", "Sci-Fi", "Tolkien's (2)", "50% off", "a+b & c" }) do
    H.test("listFolder skips its own entry when the folder name is encoded: " .. folder, function()
        local tree = { ["Books"] = "dir", ["Books/" .. folder] = "dir", ["Books/" .. folder .. "/x.epub"] = "X" }
        local api = fakeApi(tree, NC)
        local entries = assert(api:listFolder("Books/" .. folder))
        H.eq(names(entries), "x.epub")
        -- children keep their decoded name
        H.eq(names(assert(api:listFolder("Books"))), folder)
    end)
end

H.test("listFolder skips its own entry with an encoded base URL and full-URL hrefs", function()
    local tree = { ["My Books"] = "dir", ["My Books/b.epub"] = "B" }
    -- user name with a space (Nextcloud user ids can contain spaces/"@")
    local api = fakeApi(tree, "/remote.php/dav/files/john doe@x/", { full_url_href = true })
    H.eq(names(assert(api:listFolder("My Books"))), "b.epub")
end)

H.test("sync with a remote folder name containing spaces completes (issue: MY SERIES/MY SERIES 404)", function()
    local tree = { ["Books"] = "dir", ["Books/MY SERIES"] = "dir", ["Books/MY SERIES/Book.epub"] = "EPUB" }
    local api = fakeApi(tree, NC)
    local dir = H.tmpdir()
    local engine = SyncEngine.new{ webdav = api, local_dir = dir, remote_dir = "Books", direction = "upload" }
    local _, _, _, aborted = engine:run(nil)
    for _, p in ipairs(api.requested) do
        H.falsy(p:find("MY SERIES/MY SERIES", 1, true), "duplicated folder path requested: " .. p)
    end
    H.falsy(aborted, "sync aborted")
    H.rmtree(dir)
end)

H.run()
