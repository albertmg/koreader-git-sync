local FS = require("gls_fs")
local Path = require("gls_path")

local BooksSync = {}
BooksSync.__index = BooksSync

function BooksSync.new(client, settings, state)
    return setmetatable({
        client = client,
        settings = settings,
        state = state,
    }, BooksSync)
end

local function is_sidecar_or_state(rel)
    return rel:match("%.sdr/") or rel:match("%.sdr$") or rel:match("^%.")
end

function BooksSync:sync()
    local cfg = self.settings.data
    if not cfg.books_enabled then
        return true, { skipped = true, message = "Books sync is disabled" }
    end
    if not cfg.books_dir or cfg.books_dir == "" then
        return nil, "Books folder is not configured"
    end

    local remote_files, err = self.client:list_files("books")
    if not remote_files then return nil, err end

    local ok, mkdir_err = FS.ensure_dir(cfg.books_dir)
    if not ok then return nil, mkdir_err end

    local remote_by_local = {}
    local downloaded = 0
    local deleted = 0
    local unchanged = 0
    local book_state = self.state.data.books.files or {}
    self.state.data.books.files = book_state

    for remote_path, entry in pairs(remote_files) do
        local rel = remote_path:gsub("^books/", "")
        if rel ~= remote_path and rel ~= "" then
            remote_by_local[rel] = entry
            local local_path = Path.join(cfg.books_dir, rel)
            local current = book_state[rel]
            if not FS.is_file(local_path) or not current or current.remote_id ~= entry.id then
                local parent_ok, parent_err = FS.ensure_parent(local_path)
                if not parent_ok then return nil, parent_err end
                local dl_ok, dl_err = self.client:download_file(remote_path, local_path)
                if not dl_ok then return nil, dl_err end
                downloaded = downloaded + 1
            else
                unchanged = unchanged + 1
            end
            book_state[rel] = {
                remote_id = entry.id,
                size = entry.size,
                synced_at = os.time(),
            }
        end
    end

    local local_files = FS.list_files(cfg.books_dir, {
        exclude_dirs = { "%.sdr$" },
        exclude_files = { "^%.gitlibrarysync" },
    })
    for _, rel in ipairs(local_files) do
        if not remote_by_local[rel] and not is_sidecar_or_state(rel) then
            local rm_ok, rm_err = FS.remove_file(Path.join(cfg.books_dir, rel))
            if not rm_ok then return nil, rm_err end
            book_state[rel] = nil
            deleted = deleted + 1
        end
    end

    for rel in pairs(book_state) do
        if not remote_by_local[rel] then
            book_state[rel] = nil
        end
    end

    FS.remove_empty_dirs(cfg.books_dir)
    self.state:set_status("books", true)
    self.state:save()
    return true, {
        downloaded = downloaded,
        deleted = deleted,
        unchanged = unchanged,
    }
end

return BooksSync
