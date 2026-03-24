local Hash = {}

function Hash.content(content)
    content = content or ""
    local h1 = 5381
    local h2 = 0
    for i = 1, #content do
        local b = content:byte(i)
        h1 = (h1 * 33 + b) % 4294967296
        h2 = (h2 * 131 + b) % 4294967296
    end
    return string.format("%08x%08x%08x", h1, h2, #content)
end

function Hash.file(fs, file_path)
    local content = fs.read_file(file_path)
    if content == nil then return nil end
    return Hash.content(content)
end

return Hash
