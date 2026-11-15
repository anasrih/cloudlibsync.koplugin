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
-- A transfer that FAILS must not be recorded in the snapshot as "synced":
-- otherwise, on the next run, the missing side looks like a deletion and,
-- with allow_delete=true, the engine deletes the good copy.
-- ---------------------------------------------------------------------
H.test("failed upload (413) + allow_delete=true must NOT delete the local file next run", function()
    local s = sandbox({ allow_delete = true })
    s.fake.reject_413["big.cbz"] = true
    H.write(s.dir .. "/big.cbz", "BIGBIG")
    s.run()                       -- upload rejected
    s.run({ bypass_known_bad = true })
    H.truthy(H.exists(s.dir .. "/big.cbz"), "local book was deleted after a failed upload")
    s.run()                       -- auto sync again: still skipped, still kept
    H.truthy(H.exists(s.dir .. "/big.cbz"), "local book was deleted after a skipped upload")
    H.eq(s.fake:count("del:"), 0)
    s.cleanup()
end)

H.test("failed download + allow_delete=true must NOT delete the remote file next run", function()
    local s = sandbox({ allow_delete = true })
    s.fake.files["Books/new.epub"] = "NEW"
    s.fake.fail_get["new.epub"] = true
    s.run()                       -- download fails
    s.run()
    H.eq(s.fake.files["Books/new.epub"], "NEW", "remote book was deleted after a failed download")
    H.eq(s.fake:count("del:"), 0)
    s.cleanup()
end)

H.test("failed upload (network) + allow_delete=true: local kept, retried once network is back", function()
    local s = sandbox({ allow_delete = true })
    s.fake.fail_put["a.epub"] = true
    H.write(s.dir .. "/a.epub", "AAA")
    s.run()                       -- network error on PUT
    s.run()                       -- still failing
    H.truthy(H.exists(s.dir .. "/a.epub"), "local book was deleted after a failed upload")
    s.fake.fail_put["a.epub"] = nil
    s.run()                       -- network back
    H.eq(s.fake.files["Books/a.epub"], "AAA")
    s.cleanup()
end)

H.test("failed download is retried on the next run", function()
    local s = sandbox()
    s.fake.files["Books/new.epub"] = "NEW"
    s.fake.fail_get["new.epub"] = true
    s.run()
    s.fake.fail_get["new.epub"] = nil
    s.run()
    H.eq(H.read(s.dir .. "/new.epub"), "NEW")
    s.cleanup()
end)

H.test("failed upload of a MODIFIED file is retried on the next run", function()
    local s = sandbox()
    H.write(s.dir .. "/a.epub", "AAA"); s.run()
    H.write(s.dir .. "/a.epub", "AAA-EDITED")
    s.fake.fail_put["a.epub"] = true
    s.run()
    s.fake.fail_put["a.epub"] = nil
    s.run()
    H.eq(s.fake.files["Books/a.epub"], "AAA-EDITED")
    s.cleanup()
end)

H.test("failed download of a MODIFIED remote file is retried on the next run", function()
    local s = sandbox()
    H.write(s.dir .. "/a.epub", "AAA"); s.run()
    s.fake.files["Books/a.epub"] = "AAA-REMOTE-EDIT"
    s.fake.fail_get["a.epub"] = true
    s.run()
    s.fake.fail_get["a.epub"] = nil
    s.run()
    H.eq(H.read(s.dir .. "/a.epub"), "AAA-REMOTE-EDIT")
    s.cleanup()
end)

H.test("failed re-upload after remote deletion, then allow_delete switched on: local kept", function()
    local s = sandbox()
    H.write(s.dir .. "/a.epub", "AAA"); s.run()
    s.fake.files["Books/a.epub"] = nil
    s.fake.fail_put["a.epub"] = true
    s.run()                       -- allow_delete=false: restore attempt fails
    s.run({ allow_delete = true })
    H.truthy(H.exists(s.dir .. "/a.epub"), "local book was deleted after a failed restore")
    s.cleanup()
end)

H.test("failed re-download after local deletion, then allow_delete switched on: remote kept", function()
    local s = sandbox()
    H.write(s.dir .. "/a.epub", "AAA"); s.run()
    os.remove(s.dir .. "/a.epub")
    s.fake.fail_get["a.epub"] = true
    s.run()                       -- allow_delete=false: restore attempt fails
    s.run({ allow_delete = true })
    H.eq(s.fake.files["Books/a.epub"], "AAA", "remote book was deleted after a failed restore")
    s.cleanup()
end)

-- ---------- folder cover images (issue #2) ----------

H.test("isIgnored: folder covers kept, other hidden files and .sdr ignored", function()
    local ig = SyncEngine._isIgnored
    for _, n in ipairs({ ".cover.png", ".cover.jpg", ".cover.jpeg", ".cover.webp",
                         ".cover.gif", ".cover.bmp", ".cover.JPG", ".Cover.Png" }) do
        H.falsy(ig(n, false), n .. " should be synced")
    end
    for _, n in ipairs({ ".hidden", ".DS_Store", ".cover", ".cover.txt", ".cover.png.part",
                         ".covers.png", "book.sdr", ".cover.png.sdr" }) do
        H.truthy(ig(n, false), n .. " should be ignored")
    end
    H.truthy(ig(".cover.png", true), "a directory named like a cover must be ignored")
    H.falsy(ig("book.epub", false))
end)

H.test("local folder cover is uploaded, other hidden files and .sdr are not", function()
    local s = sandbox()
    H.write(s.dir .. "/SF/.cover.png", "IMG")
    H.write(s.dir .. "/SF/.hidden", "H")
    H.write(s.dir .. "/SF/book.sdr/metadata.epub.lua", "M")
    H.write(s.dir .. "/.git/.cover.png", "G") -- inside a hidden folder: ignored
    s.run()
    H.eq(s.fake.files["Books/SF/.cover.png"], "IMG")
    H.eq(s.fake:count("put:"), 1)
    s.cleanup()
end)

H.test("remote folder cover is downloaded, other hidden remote files are not", function()
    local s = sandbox()
    s.fake.files["Books/SF/.cover.JPG"] = "IMG"
    s.fake.files["Books/SF/.hidden"] = "H"
    s.run()
    H.eq(H.read(s.dir .. "/SF/.cover.JPG"), "IMG")
    H.falsy(H.exists(s.dir .. "/SF/.hidden"))
    s.cleanup()
end)

H.test("replaced folder cover (new size) is propagated", function()
    local s = sandbox()
    H.write(s.dir .. "/SF/.cover.png", "IMG1"); s.run()
    H.write(s.dir .. "/SF/.cover.png", "IMAGE-2"); s.run()
    H.eq(s.fake.files["Books/SF/.cover.png"], "IMAGE-2")
    s.cleanup()
end)

-- Servers that never list dot-files (nginx-dav-ext-module) but accept PUT.

H.test("dot-hiding server + allow_delete=true: uploaded local cover is NOT deleted next runs", function()
    local s = sandbox({ allow_delete = true })
    s.fake.hide_dotfiles = true
    H.write(s.dir .. "/SF/.cover.png", "IMG")
    s.run(); s.run(); s.run()
    H.eq(H.read(s.dir .. "/SF/.cover.png"), "IMG", "local cover deleted")
    H.eq(s.fake.files["Books/SF/.cover.png"], "IMG")
    s.cleanup()
end)

H.test("dot-hiding server: cover is uploaded once, not on every run", function()
    local s = sandbox()
    s.fake.hide_dotfiles = true
    H.write(s.dir .. "/SF/.cover.png", "IMG")
    s.run(); s.run(); s.run()
    H.eq(s.fake:count("put:"), 1)
    s.cleanup()
end)

H.test("dot-hiding server: a locally replaced cover (new size) is uploaded again", function()
    local s = sandbox()
    s.fake.hide_dotfiles = true
    H.write(s.dir .. "/SF/.cover.png", "IMG1"); s.run(); s.run()
    H.write(s.dir .. "/SF/.cover.png", "IMAGE-2"); s.run(); s.run()
    H.eq(s.fake.files["Books/SF/.cover.png"], "IMAGE-2")
    H.eq(s.fake:count("put:"), 2)
    s.cleanup()
end)

H.test("cover deleted on the server + allow_delete=true: local cover kept, not re-uploaded", function()
    local s = sandbox({ allow_delete = true })
    H.write(s.dir .. "/SF/.cover.png", "IMG"); s.run()
    s.fake.files["Books/SF/.cover.png"] = nil
    s.run(); s.run()
    H.eq(H.read(s.dir .. "/SF/.cover.png"), "IMG")
    H.eq(s.fake:count("put:"), 1)
    s.cleanup()
end)

H.test("cover deleted locally + allow_delete=true: remote cover deleted (unchanged behaviour)", function()
    local s = sandbox({ allow_delete = true })
    H.write(s.dir .. "/SF/.cover.png", "IMG"); s.run()
    os.remove(s.dir .. "/SF/.cover.png")
    s.run()
    H.eq(s.fake.files["Books/SF/.cover.png"], nil)
    s.cleanup()
end)

H.test("dot-hiding server: regular books still sync and deletions still propagate", function()
    local s = sandbox({ allow_delete = true })
    s.fake.hide_dotfiles = true
    H.write(s.dir .. "/a.epub", "AAA"); s.run()
    s.fake.files["Books/a.epub"] = nil
    s.run()
    H.falsy(H.exists(s.dir .. "/a.epub"), "remote deletion of a book must still propagate")
    s.cleanup()
end)

H.run()
