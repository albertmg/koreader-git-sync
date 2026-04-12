local Path = {}

function Path.normalize(p)
    p = tostring(p or "")
    p = p:gsub("\\", "/")
    p = p:gsub("/+", "/")
    if #p > 1 then
        p = p:gsub("/$", "")
    end
    return p
end

function Path.trim_slashes(p)
    p = Path.normalize(p)
    p = p:gsub("^/+", "")
    p = p:gsub("/+$", "")
    return p
end

function Path.join(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local part = select(i, ...)
        if part and part ~= "" then
            part = tostring(part)
            if #parts == 0 and part:sub(1, 1) == "/" then
                table.insert(parts, (Path.normalize(part):gsub("/+$", "")))
            else
                table.insert(parts, Path.trim_slashes(part))
            end
        end
    end
    local joined = table.concat(parts, "/")
    if joined == "" then return "" end
    if select(1, ...) and tostring(select(1, ...)):sub(1, 1) == "/" and joined:sub(1, 1) ~= "/" then
        joined = "/" .. joined
    end
    return Path.normalize(joined)
end

function Path.dirname(p)
    p = Path.normalize(p)
    local dir = p:match("^(.*)/[^/]*$")
    if dir == nil or dir == "" then
        return p:sub(1, 1) == "/" and "/" or "."
    end
    return dir
end

function Path.basename(p)
    p = Path.normalize(p)
    return p:match("([^/]+)$") or p
end

function Path.relative(root, full_path)
    root = Path.normalize(root)
    full_path = Path.normalize(full_path)
    if full_path == root then return "" end
    if full_path:sub(1, #root + 1) == root .. "/" then
        return full_path:sub(#root + 2)
    end
    return full_path
end

function Path.has_prefix(rel, prefix)
    rel = Path.trim_slashes(rel)
    prefix = Path.trim_slashes(prefix)
    return rel == prefix or rel:sub(1, #prefix + 1) == prefix .. "/"
end

return Path
