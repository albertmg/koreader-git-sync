local ok, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok then
    ok, lfs = pcall(require, "lfs")
end
if not ok then
    error("KOReader Git Sync requires LuaFileSystem")
end

local Path = require("gls_path")

local FS = {
    lfs = lfs,
}

local function attr(path, name)
    return lfs.attributes(path, name)
end

function FS.exists(path)
    return attr(path, "mode") ~= nil
end

function FS.is_file(path)
    return attr(path, "mode") == "file"
end

function FS.is_dir(path)
    return attr(path, "mode") == "directory"
end

function FS.mtime(path)
    return attr(path, "modification")
end

function FS.size(path)
    return attr(path, "size")
end

function FS.ensure_dir(dir)
    dir = Path.normalize(dir)
    if dir == "" or dir == "." or dir == "/" then return true end
    local current = dir:sub(1, 1) == "/" and "/" or ""
    for part in dir:gmatch("[^/]+") do
        if current == "" then
            current = part
        elseif current == "/" then
            current = "/" .. part
        else
            current = current .. "/" .. part
        end
        local mode = attr(current, "mode")
        if mode == nil then
            local made, err = lfs.mkdir(current)
            if not made then return nil, err end
        elseif mode ~= "directory" then
            return nil, current .. " exists and is not a directory"
        end
    end
    return true
end

function FS.ensure_parent(file_path)
    return FS.ensure_dir(Path.dirname(file_path))
end

function FS.read_file(file_path)
    local fh = io.open(file_path, "rb")
    if not fh then return nil end
    local content = fh:read("*a")
    fh:close()
    return content
end

function FS.write_file(file_path, content)
    local ok_parent, err = FS.ensure_parent(file_path)
    if not ok_parent then return nil, err end
    local tmp_path = file_path .. ".koreader-git-sync.tmp"
    local fh, open_err = io.open(tmp_path, "wb")
    if not fh then return nil, open_err end
    fh:write(content or "")
    fh:close()
    os.remove(file_path)
    local renamed, rename_err = os.rename(tmp_path, file_path)
    if not renamed then
        os.remove(tmp_path)
        return nil, rename_err
    end
    return true
end

function FS.remove_file(file_path)
    if FS.exists(file_path) then
        return os.remove(file_path)
    end
    return true
end

function FS.touch(file_path, mtime)
    if lfs.touch and mtime then
        pcall(lfs.touch, file_path, mtime, mtime)
    end
end

local function matches_any(rel, patterns)
    if not patterns then return false end
    for _, pattern in ipairs(patterns) do
        if rel:match(pattern) then return true end
    end
    return false
end

function FS.list_files(root, opts)
    opts = opts or {}
    root = Path.normalize(root)
    local results = {}

    local function walk(dir, prefix)
        local ok_dir, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok_dir or not iter then return end
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." then
                local full = Path.join(dir, name)
                local rel = prefix == "" and name or prefix .. "/" .. name
                rel = Path.normalize(rel)
                local mode = attr(full, "mode")
                if mode == "directory" then
                    if not matches_any(rel, opts.exclude_dirs) and not matches_any(name, opts.exclude_dir_names) then
                        walk(full, rel)
                    end
                elseif mode == "file" then
                    if not matches_any(rel, opts.exclude_files) then
                        if not opts.include_file or opts.include_file(rel, full) then
                            table.insert(results, rel)
                        end
                    end
                end
            end
        end
    end

    if FS.is_dir(root) then
        walk(root, "")
    end
    table.sort(results)
    return results
end

function FS.remove_empty_dirs(root)
    root = Path.normalize(root)
    if not FS.is_dir(root) then return end
    local function walk(dir)
        local empty = true
        local iter, dir_obj = lfs.dir(dir)
        if not iter then return false end
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." then
                local full = Path.join(dir, name)
                if attr(full, "mode") == "directory" then
                    if not walk(full) then empty = false end
                else
                    empty = false
                end
            end
        end
        if dir ~= root and empty then
            lfs.rmdir(dir)
            return true
        end
        return empty
    end
    walk(root)
end

return FS
