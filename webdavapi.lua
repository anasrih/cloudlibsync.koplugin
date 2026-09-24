--[[--
Minimal, self-contained WebDAV client (doesn't depend on plugins/cloudstorage).

Uses LuaSocket/LuaSec (already bundled with KOReader) to speak HTTP(S), and
does tolerant XML "sniffing" (namespace prefixes vary by server: D:, d:,
lp1:, etc.) rather than a real XML parser.

Tested conceptually against Apache mod_dav / Nextcloud / OMV-webdav. If your
server returns a slightly different format, this is where to adjust
`parsePropfindBody`.
--]]--

local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local mime = require("mime")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local logger = require("logger")

local WebDavApi = {}
WebDavApi.__index = WebDavApi

-- Network timeouts: short for metadata operations (listing, folder
-- creation, deletion), much larger for actual file transfers (GET/PUT),
-- where a big epub or an audiobook on slow wifi can take several minutes.
-- socketutil.LARGE_* (10s/30s) is meant by KOReader for small responses,
-- not transfers.
local BLOCK_TIMEOUT_METADATA = socketutil.LARGE_BLOCK_TIMEOUT
local TOTAL_TIMEOUT_METADATA = socketutil.LARGE_TOTAL_TIMEOUT
local BLOCK_TIMEOUT_TRANSFER = 30
local TOTAL_TIMEOUT_TRANSFER = 600 -- 10 min

-- Strips any "scheme://host[:port]" to keep only the path — used to
-- compare a WebDAV response href (often just a path, sometimes a full URL
-- depending on the server) to a locally built URL, without ever treating
-- these strings as Lua patterns.
local function stripHost(u)
    return (u:gsub("^%a[%w+.-]*://[^/]+", ""))
end

function WebDavApi.new(o)
    -- o = { url = "https://webdav.example.com/", user = "...", pass = "..." }
    local self = setmetatable({}, WebDavApi)
    self.url = o.url
    if not self.url:match("/$") then
        self.url = self.url .. "/"
    end
    self.user = o.user
    self.pass = o.pass
    return self
end

function WebDavApi:_authHeader()
    if self.user and self.user ~= "" then
        return "Basic " .. mime.b64((self.user or "") .. ":" .. (self.pass or ""))
    end
    return nil
end

-- Builds the absolute URL from a relative path (each segment is escaped
-- separately to preserve the "/").
function WebDavApi:_buildUrl(rel_path)
    rel_path = rel_path or ""
    rel_path = rel_path:gsub("^/+", "")
    local segments = {}
    for seg in rel_path:gmatch("[^/]+") do
        table.insert(segments, socket_url.escape(seg))
    end
    return self.url .. table.concat(segments, "/")
end

-- method: "GET" | "PUT" | "DELETE" | "MKCOL" | "PROPFIND"
-- body_source (optional): { str = "<text body>" } for PROPFIND, or
--   { file_path = "<local path>" } for PUT. A fresh body is rebuilt on
--   every attempt, since a redirect requires being able to resend it.
-- sink_factory (optional): function() -> ltn12 sink, called on every
--   attempt (GET: reopens the local file for writing on each try).
-- returns: ok(boolean), status_or_err, response_body(string|nil), response_headers
local MAX_REDIRECTS = 5

function WebDavApi:_request(method, rel_path, extra_headers, body_source, sink_factory)
    local target_url = self:_buildUrl(rel_path)

    local headers = {}
    for k, v in pairs(extra_headers or {}) do headers[k] = v end
    local auth = self:_authHeader()
    if auth then headers["Authorization"] = auth end

    for attempt = 1, MAX_REDIRECTS do
        local requester = target_url:match("^https:") and https or http

        local source = nil
        if body_source then
            if body_source.str then
                source = ltn12.source.string(body_source.str)
            elseif body_source.file_path then
                local fh = io.open(body_source.file_path, "rb")
                if not fh then return false, "cannot open local file" end
                source = ltn12.source.file(fh)
            end
        end
        local response_chunks = {}
        local sink = sink_factory and sink_factory() or ltn12.sink.table(response_chunks)

        local is_transfer = (method == "GET" or method == "PUT")
        local block_t = is_transfer and BLOCK_TIMEOUT_TRANSFER or BLOCK_TIMEOUT_METADATA
        local total_t = is_transfer and TOTAL_TIMEOUT_TRANSFER or TOTAL_TIMEOUT_METADATA
        socketutil:set_timeout(block_t, total_t)
        local ok, status_or_err, resp_headers = requester.request({
            url = target_url,
            method = method,
            headers = headers,
            source = source,
            sink = sink,
            redirect = false, -- handled ourselves below, so we can resend the body
        })
        socketutil:reset_timeout()

        if not ok then
            logger.warn("CloudLibSync WebDAV:", method, rel_path, "network error:", status_or_err)
            return false, status_or_err
        end

        local status = status_or_err
        if status == 301 or status == 302 or status == 303 or status == 307 or status == 308 then
            local location = resp_headers and (resp_headers.location or resp_headers["Location"])
            if not location then
                logger.warn("CloudLibSync WebDAV:", method, rel_path, "redirect", status, "with no Location header")
                return false, status
            end
            target_url = socket_url.absolute(target_url, location)
            logger.info("CloudLibSync WebDAV: redirect", status, "to", target_url)
            -- loop: retry against target_url, with a fresh body
        else
            local body = table.concat(response_chunks)
            if type(status) == "number" and (status == 200 or status == 201 or status == 204 or status == 207) then
                return true, status, body, resp_headers
            end
            logger.warn("CloudLibSync WebDAV:", method, rel_path, "HTTP", status, body and body:sub(1, 200))
            return false, status, body, resp_headers
        end
    end
    logger.warn("CloudLibSync WebDAV:", method, rel_path, "too many redirects (>", MAX_REDIRECTS, ")")
    return false, "too many redirects"
end

-- Tolerant XML extraction, agnostic of namespace prefixes.
local function parsePropfindBody(xml_body)
    local entries = {}
    for block in xml_body:gmatch("<[%a][%w:.-]-[Rr]esponse[^>]*>(.-)</[%a][%w:.-]-[Rr]esponse>") do
        local href = block:match("<[%a][%w:.-]-href[^>]*>%s*(.-)%s*</[%a][%w:.-]-href>")
        if href then
            href = socket_url.unescape(href)
            local is_dir = (block:match("<[%a][%w:.-]-collection%s*/>") ~= nil)
                or (block:match("<[%a][%w:.-]-collection%s*>") ~= nil)
            local size = tonumber(block:match("<[%a][%w:.-]-getcontentlength[^>]*>%s*(%d+)%s*<"))
            local mtime = block:match("<[%a][%w:.-]-getlastmodified[^>]*>%s*(.-)%s*<")
            table.insert(entries, { href = href, is_dir = is_dir, size = size, mtime = mtime })
        end
    end
    return entries
end

-- Lists the contents of a remote folder (non-recursive, Depth: 1).
-- Returns a table of { name=, is_dir=, size=, mtime= } (excluding the
-- folder itself).
function WebDavApi:listFolder(rel_path)
    local body = [[<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:resourcetype/>
    <D:getcontentlength/>
    <D:getlastmodified/>
  </D:prop>
</D:propfind>]]
    local ok, status, resp_body = self:_request("PROPFIND", rel_path, {
        ["Depth"] = "1",
        ["Content-Type"] = "application/xml; charset=utf-8",
        ["Content-Length"] = tostring(#body), -- required by most WebDAV servers
    }, { str = body })

    if not ok then
        return nil, status
    end

    local raw_entries = parsePropfindBody(resp_body)
    -- Compare paths only (no scheme://host), never using these strings as a
    -- Lua pattern (they can contain special characters such as "%" or "."
    -- from encoding or from the name itself).
    local self_path = stripHost(self:_buildUrl(rel_path)):gsub("/+$", "")
    local results = {}
    for _, e in ipairs(raw_entries) do
        local href_path = stripHost(e.href):gsub("/+$", "")
        if href_path ~= self_path then
            local name = href_path:match("([^/]+)$")
            if name then
                table.insert(results, {
                    name = name,
                    is_dir = e.is_dir,
                    size = e.size,
                    mtime = e.mtime,
                })
            end
        end
    end
    return results
end

-- Creates a remote folder (ignores the "already exists" error, status 405).
function WebDavApi:makeFolder(rel_path)
    local ok, status = self:_request("MKCOL", rel_path)
    if ok or status == 405 then
        return true
    end
    return false, status
end

-- Ensures the whole remote folder path exists (creates it recursively).
function WebDavApi:ensureFolderPath(rel_path)
    local parts = {}
    for seg in rel_path:gmatch("[^/]+") do table.insert(parts, seg) end
    local acc = ""
    for _, seg in ipairs(parts) do
        acc = (acc == "") and seg or (acc .. "/" .. seg)
        self:makeFolder(acc)
    end
    return true
end

-- Recursively creates a local folder ("mkdir -p" style).
local function ensureLocalDir(path)
    if not path or path == "" then return end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") then return end
    local parent = path:match("^(.*)/[^/]+$")
    if parent then ensureLocalDir(parent) end
    lfs.mkdir(path)
end

-- Downloads a remote file to a local path.
function WebDavApi:downloadFile(rel_path, local_path)
    local dir = local_path:match("^(.*)/[^/]+$")
    if dir then ensureLocalDir(dir) end
    local ok, status = self:_request("GET", rel_path, nil, nil, function()
        local out = io.open(local_path .. ".part", "wb")
        return ltn12.sink.file(out)
    end)
    if not ok then
        os.remove(local_path .. ".part")
        return false, status
    end
    os.rename(local_path .. ".part", local_path)
    return true
end

-- Sends a local file to the remote path (creates parent folders).
function WebDavApi:uploadFile(local_path, rel_path)
    local parent = rel_path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then
        self:ensureFolderPath(parent)
    end
    local attr = require("libs/libkoreader-lfs").attributes(local_path)
    if not attr then return false, "local file missing" end
    local ok, status = self:_request("PUT", rel_path, {
        ["Content-Length"] = tostring(attr.size),
    }, { file_path = local_path })
    return ok, status
end

function WebDavApi:deleteFile(rel_path)
    local ok, status = self:_request("DELETE", rel_path)
    return ok, status
end

return WebDavApi
