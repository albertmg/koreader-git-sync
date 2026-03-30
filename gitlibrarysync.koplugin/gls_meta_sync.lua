local FS = require("gls_fs")
local Hash = require("gls_hash")
local Manifest = require("gls_manifest")
local Path = require("gls_path")

local MetaSync = {}
MetaSync.__index = MetaSync

local MANIFEST_PATH = "meta/.gitlibrarysync-manifest.json"

function MetaSync.new(client, settings, state)
    return setmetatable({
        client = client,
        settings = settings,
        state = state,
    }, MetaSync)
end

local function metadata_rel(local_rel)
    if local_rel:match("%.sdr/") then
        return local_rel
    end
    return nil
end

function MetaSync:local_files()
    local cfg = self.settings.data
    local files = {}
    local rels = FS.list_files(cfg.books_dir, {
        include_file = function(rel)
            return metadata_rel(rel) ~= nil
        end,
    })
    for _, local_rel in ipairs(rels) do
        local rel = metadata_rel(local_rel)
        local full_path = Path.join(cfg.books_dir, local_rel)
        local content = FS.read_file(full_path)
        if content then
            files[rel] = {
                rel = rel,
                path = full_path,
                hash = Hash.content(content),
                mtime = FS.mtime(full_path) or os.time(),
            }
        end
    end
    return files
end

local function union_keys(...)
    local keys = {}
    for i = 1, select("#", ...) do
        local map = select(i, ...)
        for k in pairs(map or {}) do
            keys[k] = true
        end
    end
    return keys
end

local function strip_prefix(remote_map, prefix)
    local result = {}
    for remote_path, entry in pairs(remote_map or {}) do
        local rel = remote_path:gsub("^" .. prefix .. "/", "")
        if rel ~= remote_path and rel ~= ".gitlibrarysync-manifest.json" then
            result[rel] = entry
        end
    end
    return result
end

function MetaSync:sync()
    local cfg = self.settings.data
    if not cfg.meta_enabled then
        return true, { skipped = true, message = "Metadata sync is disabled" }
    end
    if not cfg.books_dir or cfg.books_dir == "" then
        return nil, "Books folder is not configured"
    end

    local remote_tree, err = self.client:list_files("meta")
    if not remote_tree then return nil, err end
    local remote_files = strip_prefix(remote_tree, "meta")
    local manifest, manifest_exists, manifest_err = Manifest.load(self.client, MANIFEST_PATH, cfg.device_name)
    if not manifest then return nil, manifest_err end
    manifest.files = manifest.files or {}

    local local_files = self:local_files()
    local previous = self.state.data.meta.files or {}
    self.state.data.meta.files = previous

    local actions = {}
    local downloaded = 0
    local uploaded = 0
    local deleted_local = 0
    local deleted_remote = 0
    local unchanged = 0
    local now = os.time()
    local final_state = {}

    for rel in pairs(union_keys(local_files, remote_files, previous, manifest.files)) do
        local local_file = local_files[rel]
        local remote_entry = remote_files[rel]
        local remote_manifest = manifest.files[rel]
        local remote_exists = remote_entry ~= nil
        local remote_hash = remote_manifest and remote_manifest.hash or (remote_entry and remote_entry.id)
        local remote_mtime = remote_manifest and remote_manifest.mtime or 0
        local previous_entry = previous[rel]

        if local_file and remote_exists then
            if local_file.hash == remote_hash then
                unchanged = unchanged + 1
                manifest.files[rel] = {
                    hash = local_file.hash,
                    mtime = math.max(local_file.mtime, remote_mtime or 0),
                    deleted = false,
                    device = remote_manifest and remote_manifest.device or cfg.device_name,
                }
            elseif local_file.mtime >= remote_mtime then
                table.insert(actions, {
                    action = remote_entry and "update" or "create",
                    file_path = "meta/" .. rel,
                    content = FS.read_file(local_file.path),
                })
                manifest.files[rel] = {
                    hash = local_file.hash,
                    mtime = local_file.mtime,
                    deleted = false,
                    device = cfg.device_name,
                }
                uploaded = uploaded + 1
            else
                local ok = self.client:download_file("meta/" .. rel, local_file.path)
                if not ok then return nil, "Cannot download metadata " .. rel end
                FS.touch(local_file.path, remote_mtime)
                local content = FS.read_file(local_file.path) or ""
                local new_hash = Hash.content(content)
                manifest.files[rel] = {
                    hash = new_hash,
                    mtime = remote_mtime,
                    deleted = false,
                    device = remote_manifest and remote_manifest.device or "remote",
                }
                downloaded = downloaded + 1
            end
        elseif local_file and not remote_exists then
            local remote_deleted_mtime = remote_manifest and remote_manifest.deleted and remote_manifest.mtime or 0
            if remote_deleted_mtime > local_file.mtime then
                local rm_ok, rm_err = FS.remove_file(local_file.path)
                if not rm_ok then return nil, rm_err end
                manifest.files[rel] = remote_manifest
                deleted_local = deleted_local + 1
            else
                table.insert(actions, {
                    action = "create",
                    file_path = "meta/" .. rel,
                    content = FS.read_file(local_file.path),
                })
                manifest.files[rel] = {
                    hash = local_file.hash,
                    mtime = local_file.mtime,
                    deleted = false,
                    device = cfg.device_name,
                }
                uploaded = uploaded + 1
            end
        elseif not local_file and remote_exists then
            local local_delete_mtime = previous_entry and not previous_entry.deleted and now or 0
            if local_delete_mtime > remote_mtime then
                table.insert(actions, {
                    action = "delete",
                    file_path = "meta/" .. rel,
                })
                manifest.files[rel] = {
                    hash = previous_entry and previous_entry.hash or remote_hash,
                    mtime = local_delete_mtime,
                    deleted = true,
                    device = cfg.device_name,
                }
                deleted_remote = deleted_remote + 1
            else
                local local_path = Path.join(cfg.books_dir, rel)
                local parent_ok, parent_err = FS.ensure_parent(local_path)
                if not parent_ok then return nil, parent_err end
                local ok = self.client:download_file("meta/" .. rel, local_path)
                if not ok then return nil, "Cannot download metadata " .. rel end
                FS.touch(local_path, remote_mtime)
                local content = FS.read_file(local_path) or ""
                local new_hash = Hash.content(content)
                manifest.files[rel] = {
                    hash = new_hash,
                    mtime = remote_mtime > 0 and remote_mtime or now,
                    deleted = false,
                    device = remote_manifest and remote_manifest.device or "remote",
                }
                downloaded = downloaded + 1
            end
        elseif previous_entry and not previous_entry.deleted then
            local delete_mtime = now
            manifest.files[rel] = {
                hash = previous_entry.hash,
                mtime = delete_mtime,
                deleted = true,
                device = cfg.device_name,
            }
        end
    end

    for rel, entry in pairs(manifest.files) do
        final_state[rel] = entry
    end

    if #actions > 0 or not manifest_exists then
        table.insert(actions, Manifest.action(remote_tree, MANIFEST_PATH, Manifest.encode(manifest, cfg.device_name)))
        local committed, commit_err = self.client:commit(actions, "Sync KOReader metadata from " .. cfg.device_name)
        if not committed then return nil, commit_err end
    end

    self.state.data.meta.files = final_state
    self.state:set_status("meta", true)
    self.state:save()
    return true, {
        uploaded = uploaded,
        downloaded = downloaded,
        deleted_local = deleted_local,
        deleted_remote = deleted_remote,
        unchanged = unchanged,
    }
end

return MetaSync
