local JSON = require("json")

local Manifest = {}

function Manifest.empty(device_name)
    return {
        version = 1,
        device = device_name,
        updated_at = os.time(),
        files = {},
    }
end

function Manifest.decode(content, device_name)
    if not content or content == "" then
        return Manifest.empty(device_name), false
    end
    local ok, decoded = pcall(JSON.decode, content)
    if not ok or type(decoded) ~= "table" then
        return Manifest.empty(device_name), false
    end
    decoded.files = decoded.files or {}
    return decoded, true
end

function Manifest.encode(manifest, device_name)
    manifest.version = 1
    manifest.device = device_name
    manifest.updated_at = os.time()
    manifest.files = manifest.files or {}
    return JSON.encode(manifest)
end

function Manifest.load(client, remote_path, device_name)
    local content, err = client:get_raw(remote_path)
    if not content then
        if err and not tostring(err):match("HTTP 404") then
            return nil, nil, err
        end
        return Manifest.empty(device_name), false, err
    end
    local manifest = Manifest.decode(content, device_name)
    return manifest, true
end

function Manifest.action(remote_map, remote_path, content)
    return {
        action = remote_map[remote_path] and "update" or "create",
        file_path = remote_path,
        content = content,
    }
end

return Manifest
