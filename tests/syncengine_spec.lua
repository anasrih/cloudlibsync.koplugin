package.path = ((arg and arg[0] or ""):match("^(.*)/[^/]+$") or ".") .. "/?.lua;" .. package.path
local H = require("harness")
local SyncEngine = require("syncengine")

-- Builds a fresh sandbox: local dir + fake server + engine factory.
local function sandbox(opts)
    opts = opts or {}
    local s = { dir = H.tmpdir(), fake = H.FakeWebDav(), snapshot = nil, known_bad = {} }
    function s.run(o)
        o = o or {}
        local engine = SyncEngine.new{
            webdav = s.fake,
            local_dir = s.dir,
            remote_dir = "Books",
            direction = o.direction or opts.direction or "both",
            allow_delete = (o.allow_delete == nil) and (opts.allow_delete or false) or o.allow_delete,
            known_bad = o.known_bad or s.known_bad,
            bypass_known_bad = o.bypass_known_bad or false,
        }
        local snap, summary, new_bad, aborted = engine:run(s.snapshot)
        if not aborted then s.snapshot = snap; s.known_bad = new_bad end -- same contract as main.lua
        return summary, new_bad, aborted
    end
    function s.cleanup() H.rmtree(s.dir) end
    return s
end

H.test("new local file is uploaded", function()
    local s = sandbox()
    H.write(s.dir .. "/a.epub", "AAA")
    s.run()
    H.eq(s.fake.files["Books/a.epub"], "AAA")
    s.cleanup()
end)

H.test("new remote file is downloaded, including its subfolder", function()
    local s = sandbox()
    s.fake.files["Books/sub/b.epub"] = "BBB"
    s.run()
    H.eq(H.read(s.dir .. "/sub/b.epub"), "BBB")
    s.cleanup()
end)

H.test("second run with nothing changed does no transfer", function()
    local s = sandbox()
    H.write(s.dir .. "/a.epub", "AAA")
    s.run(); s.run()
    H.eq(s.fake:count("put:"), 1)
    H.eq(s.fake:count("get:"), 0)
    s.cleanup()
end)

H.test("direction=upload never downloads", function()
    local s = sandbox({ direction = "upload" })
    s.fake.files["Books/r.epub"] = "R"
    s.run()
    H.falsy(H.exists(s.dir .. "/r.epub"))
    s.cleanup()
end)

H.test("direction=download never uploads", function()
    local s = sandbox({ direction = "download" })
    H.write(s.dir .. "/l.epub", "L")
    s.run()
    H.eq(s.fake:count("put:"), 0)
    s.cleanup()
end)

H.test("local deletion + allow_delete=false: file is restored locally, remote untouched", function()
    local s = sandbox()
    H.write(s.dir .. "/a.epub", "AAA"); s.run()
    os.remove(s.dir .. "/a.epub")
    s.run()
    H.eq(H.read(s.dir .. "/a.epub"), "AAA")
    H.eq(s.fake:count("del:"), 0)
    s.cleanup()
end)

H.test("local deletion + allow_delete=true: remote copy is deleted", function()
    local s = sandbox({ allow_delete = true })
    H.write(s.dir .. "/a.epub", "AAA"); s.run()
    os.remove(s.dir .. "/a.epub")
    s.run()
    H.falsy(s.fake.files["Books/a.epub"])
    H.falsy(H.exists(s.dir .. "/a.epub"))
    s.cleanup()
end)

H.test("remote deletion + allow_delete=true: local copy is deleted", function()
    local s = sandbox({ allow_delete = true })
    H.write(s.dir .. "/a.epub", "AAA"); s.run()
    s.fake.files["Books/a.epub"] = nil
    s.run()
    H.falsy(H.exists(s.dir .. "/a.epub"))
    s.cleanup()
end)

H.test("remote deletion + allow_delete=false: file is re-uploaded", function()
    local s = sandbox()
    H.write(s.dir .. "/a.epub", "AAA"); s.run()
    s.fake.files["Books/a.epub"] = nil
    s.run()
    H.eq(s.fake.files["Books/a.epub"], "AAA")
    s.cleanup()
end)

H.test("failed REMOTE scan aborts and deletes nothing (allow_delete=true)", function()
    local s = sandbox({ allow_delete = true })
    H.write(s.dir .. "/a.epub", "AAA"); s.run()
    s.fake.fail_list = true
    local _, _, aborted = s.run()
    H.truthy(aborted)
    H.truthy(H.exists(s.dir .. "/a.epub"))
    H.eq(s.fake:count("del:"), 0)
    s.cleanup()
end)

H.test("failed LOCAL scan aborts and deletes nothing on the server (allow_delete=true)", function()
    local s = sandbox({ allow_delete = true })
    H.write(s.dir .. "/a.epub", "AAA"); s.run()
    H.rmtree(s.dir) -- local folder vanishes (SD card removed...)
    local _, _, aborted = s.run()
    H.truthy(aborted)
    H.eq(s.fake.files["Books/a.epub"], "AAA")
    H.eq(s.fake:count("del:"), 0)
end)

H.test("413 is remembered: skipped on auto sync, retried on manual sync", function()
    local s = sandbox()
    s.fake.reject_413["big.cbz"] = true
    H.write(s.dir .. "/big.cbz", "BIGBIG")
    local _, bad = s.run()
    H.eq(bad["big.cbz"], 6)
    local puts = s.fake:count("put:")
    s.run()                                   -- auto: must not retry
    H.eq(s.fake:count("put:"), puts)
    s.run({ bypass_known_bad = true })        -- manual: retries
    H.eq(s.fake:count("put:"), puts + 1)
    s.cleanup()
end)

H.test("conflict (changed on both sides) overwrites nothing", function()
    local s = sandbox()
    H.write(s.dir .. "/a.epub", "AAA"); s.run()
    H.write(s.dir .. "/a.epub", "LOCAL-CHANGED")
    s.fake.files["Books/a.epub"] = "REMOTE-CHANGED-LONGER"
    s.run()
    H.eq(H.read(s.dir .. "/a.epub"), "LOCAL-CHANGED")
    H.eq(s.fake.files["Books/a.epub"], "REMOTE-CHANGED-LONGER")
    s.cleanup()
end)

-- ---------------------------------------------------------------------
-- KNOWN BUGS (expected to fail today). Found while writing this harness.
-- A transfer that FAILS is still recorded in the snapshot as "synced".
-- On the next run the missing side then looks like a deletion, and with
-- allow_delete=true the engine deletes the good copy.
-- ---------------------------------------------------------------------
H.bug("failed upload (413) + allow_delete=true must NOT delete the local file next run", function()
    local s = sandbox({ allow_delete = true })
    s.fake.reject_413["big.cbz"] = true
    H.write(s.dir .. "/big.cbz", "BIGBIG")
    s.run()                       -- upload rejected
    s.run({ bypass_known_bad = true })
    H.truthy(H.exists(s.dir .. "/big.cbz"), "local book was deleted after a failed upload")
    s.cleanup()
end)

H.bug("failed download + allow_delete=true must NOT delete the remote file next run", function()
    local s = sandbox({ allow_delete = true })
    s.fake.files["Books/new.epub"] = "NEW"
    s.fake.fail_get["new.epub"] = true
    s.run()                       -- download fails
    s.run()
    H.eq(s.fake.files["Books/new.epub"], "NEW", "remote book was deleted after a failed download")
    s.cleanup()
end)

H.run()
