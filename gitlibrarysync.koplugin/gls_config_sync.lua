local FS = require("gls_fs")
local Hash = require("gls_hash")
local Manifest = require("gls_manifest")
local Path = require("gls_path")

local ConfigSync = {}
ConfigSync.__index = ConfigSync

local MANIFEST_PATH = "config/.gitlibrarysync-manifest.json"

function ConfigSync.new(client, settings, state)
    return setmetatable({
        client = client,
        settings = settings,
        state = state,
    }, ConfigSync)
end

local function excluded_config_path(rel)
    local lower = rel:lower()
    if lower:match("^gitlibrarysync%.lua$") then return true end
    if lower:find("gitlibrarysync", 1, true) then return true end
    if lower:find("token", 1, true) then return true end
    if lower:find("password", 1, true) then return true end
    if lower:find("passwd", 1, true) then return true end
    if lower:find("secret", 1, true) then return true end
    if lower:find("credential", 1, true) then return true end
    if lower:find("cookie", 1, true) then return true end
    if lower:find("session", 1, true) then return true end
    if lower:find("network", 1, true) then return true end
    if lower:find("device", 1, true) then return true end
    if lower:find("cache", 1, true) then return true end
    if lower:match("%.log$") then return true end
    if lower:match("^crash") then return true end
    return false
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
        if rel ~= remote_path and rel ~= ".gitlibrarysync-manifest.json" and not excluded_config_path(rel) then
            result[rel] = entry
        end
    end
    return result
end

function ConfigSync:local_files()
    local cfg = self.settings.data
    local files = {}
    local rels = FS.list_files(cfg.config_dir, {
        include_file = function(rel)
            return not excluded_config_path(rel)
        end,
        exclude_dirs = {
            "cache",
            "logs?",
        },
    })
    for _, rel in ipairs(rels) do
        local full_path = Path.join(cfg.config_dir, rel)
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

function ConfigSync:prepare()
    local cfg = self.settings.data
    if not cfg.config_enabled then
        return true, { skipped = true, message = "Config sync is disabled" }
    end
    if not cfg.config_dir or cfg.config_dir == "" then
        return nil, "Config folder is not configured"
    end

    local remote_tree, err = self.client:list_files("config")
    if not remote_tree then return nil, err end
    local remote_files = strip_prefix(remote_tree, "config")
    local manifest, manifest_exists, manifest_err = Manifest.load(self.client, MANIFEST_PATH, cfg.device_name)
    if not manifest then return nil, manifest_err end
    manifest.files = manifest.files or {}

    local local_files = self:local_files()
    local previous = self.state.data.config.files or {}
    local plan = {
        remote_tree = remote_tree,
        remote_files = remote_files,
        manifest = manifest,
        manifest_exists = manifest_exists,
        local_files = local_files,
        previous = previous,
        operations = {},
        conflicts = {},
        counts = {
            uploaded = 0,
            downloaded = 0,
            deleted_local = 0,
            deleted_remote = 0,
            unchanged = 0,
            skipped = 0,
        },
    }

    for rel in pairs(union_keys(local_files, remote_files, previous, manifest.files)) do
        if not excluded_config_path(rel) then
            local local_file = local_files[rel]
            local remote_entry = remote_files[rel]
            local remote_manifest = manifest.files[rel]
            local previous_entry = previous[rel]
            local remote_hash = remote_manifest and remote_manifest.hash or (remote_entry and remote_entry.id)
            local remote_exists = remote_entry ~= nil
            local local_exists = local_file ~= nil
            local local_changed
            local remote_changed

            if local_exists then
                local_changed = not previous_entry or previous_entry.deleted or previous_entry.hash ~= local_file.hash
            else
                local_changed = previous_entry and not previous_entry.deleted
            end

            if remote_exists then
                remote_changed = not previous_entry or previous_entry.deleted or previous_entry.hash ~= remote_hash
            else
                remote_changed = previous_entry and not previous_entry.remote_deleted
            end

            if local_exists and remote_exists and local_file.hash == remote_hash then
                plan.counts.unchanged = plan.counts.unchanged + 1
                table.insert(plan.operations, { type = "keep", rel = rel })
            elseif local_changed and remote_changed then
                table.insert(plan.conflicts, {
                    rel = rel,
                    local_exists = local_exists,
                    remote_exists = remote_exists,
                    local_hash = local_file and local_file.hash,
                    remote_hash = remote_hash,
                })
            elseif local_exists and not remote_exists then
                table.insert(plan.operations, { type = "upload", rel = rel, action = "create" })
            elseif not local_exists and remote_exists then
                table.insert(plan.operations, { type = "download", rel = rel })
            elseif local_changed then
                if local_exists then
                    table.insert(plan.operations, { type = "upload", rel = rel, action = remote_exists and "update" or "create" })
                else
                    table.insert(plan.operations, { type = "delete_remote", rel = rel })
                end
            elseif remote_changed then
                if remote_exists then
                    table.insert(plan.operations, { type = "download", rel = rel })
                else
                    table.insert(plan.operations, { type = "delete_local", rel = rel })
                end
            else
                plan.counts.unchanged = plan.counts.unchanged + 1
                table.insert(plan.operations, { type = "keep", rel = rel })
            end
        end
    end

    return true, plan
end

function ConfigSync:apply(plan, choices)
    choices = choices or {}
    local cfg = self.settings.data
    local actions = {}
    local final_state = {}
    local manifest = plan.manifest
    manifest.files = manifest.files or {}

    local function mark_file(rel, hash, mtime, deleted)
        manifest.files[rel] = {
            hash = hash,
            mtime = mtime or os.time(),
            deleted = deleted or false,
            device = cfg.device_name,
        }
    end

    local function upload(rel, action)
        local local_file = plan.local_files[rel]
        if not local_file then return end
        table.insert(actions, {
            action = action or (plan.remote_files[rel] and "update" or "create"),
            file_path = "config/" .. rel,
            content = FS.read_file(local_file.path),
        })
        mark_file(rel, local_file.hash, local_file.mtime, false)
        plan.counts.uploaded = plan.counts.uploaded + 1
    end

    local function download(rel)
        local local_path = Path.join(cfg.config_dir, rel)
        local parent_ok, parent_err = FS.ensure_parent(local_path)
        if not parent_ok then return nil, parent_err end
        local ok, err = self.client:download_file("config/" .. rel, local_path)
        if not ok then return nil, err end
        local content = FS.read_file(local_path) or ""
        local hash = Hash.content(content)
        local remote_manifest = manifest.files[rel]
        local mtime = remote_manifest and remote_manifest.mtime or os.time()
        FS.touch(local_path, mtime)
        mark_file(rel, hash, mtime, false)
        plan.counts.downloaded = plan.counts.downloaded + 1
        return true
    end

    local function delete_remote(rel)
        if plan.remote_files[rel] then
            table.insert(actions, {
                action = "delete",
                file_path = "config/" .. rel,
            })
        end
        local previous = plan.previous[rel]
        mark_file(rel, previous and previous.hash, os.time(), true)
        plan.counts.deleted_remote = plan.counts.deleted_remote + 1
    end

    local function delete_local(rel)
        local local_path = Path.join(cfg.config_dir, rel)
        local ok, err = FS.remove_file(local_path)
        if not ok then return nil, err end
        local remote_manifest = manifest.files[rel]
        mark_file(rel, remote_manifest and remote_manifest.hash, remote_manifest and remote_manifest.mtime or os.time(), true)
        plan.counts.deleted_local = plan.counts.deleted_local + 1
        return true
    end

    local function apply_operation(op)
        if op.type == "upload" then
            upload(op.rel, op.action)
        elseif op.type == "download" then
            local ok, err = download(op.rel)
            if not ok then return nil, err end
        elseif op.type == "delete_remote" then
            delete_remote(op.rel)
        elseif op.type == "delete_local" then
            local ok, err = delete_local(op.rel)
            if not ok then return nil, err end
        elseif op.type == "keep" then
            local local_file = plan.local_files[op.rel]
            local remote_manifest = manifest.files[op.rel]
            if local_file then
                mark_file(op.rel, local_file.hash, local_file.mtime, false)
            elseif remote_manifest then
                manifest.files[op.rel] = remote_manifest
            end
        end
        return true
    end

    for _, op in ipairs(plan.operations) do
        local ok, err = apply_operation(op)
        if not ok then return nil, err end
    end

    for _, conflict in ipairs(plan.conflicts) do
        local choice = choices[conflict.rel] or "skip"
        if choice == "local" then
            if conflict.local_exists then
                upload(conflict.rel, conflict.remote_exists and "update" or "create")
            else
                delete_remote(conflict.rel)
            end
        elseif choice == "remote" then
            if conflict.remote_exists then
                local ok, err = download(conflict.rel)
                if not ok then return nil, err end
            else
                local ok, err = delete_local(conflict.rel)
                if not ok then return nil, err end
            end
        else
            plan.counts.skipped = plan.counts.skipped + 1
        end
    end

    if #actions > 0 or not plan.manifest_exists then
        table.insert(actions, Manifest.action(plan.remote_tree, MANIFEST_PATH, Manifest.encode(manifest, cfg.device_name)))
        local committed, commit_err = self.client:commit(actions, "Sync KOReader config from " .. cfg.device_name)
        if not committed then return nil, commit_err end
    end

    for rel, entry in pairs(manifest.files) do
        final_state[rel] = entry
    end
    self.state.data.config.files = final_state
    self.state:set_status("config", true)
    self.state:save()
    return true, plan.counts
end

function ConfigSync:sync_with_choices(choices)
    local ok, plan_or_err = self:prepare()
    if not ok then return nil, plan_or_err end
    if plan_or_err.skipped then return true, plan_or_err end
    return self:apply(plan_or_err, choices)
end

return ConfigSync
