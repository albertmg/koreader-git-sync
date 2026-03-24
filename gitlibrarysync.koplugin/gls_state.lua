local JSON = require("json")
local FS = require("gls_fs")

local State = {}
State.__index = State

local function default_data()
    return {
        version = 1,
        books = { files = {}, last_sync = nil, last_error = nil },
        meta = { files = {}, last_sync = nil, last_error = nil },
        config = { files = {}, last_sync = nil, last_error = nil },
    }
end

local function ensure_shape(data)
    data = type(data) == "table" and data or default_data()
    data.books = data.books or { files = {} }
    data.meta = data.meta or { files = {} }
    data.config = data.config or { files = {} }
    data.books.files = data.books.files or {}
    data.meta.files = data.meta.files or {}
    data.config.files = data.config.files or {}
    return data
end

function State.open(path)
    local self = setmetatable({ path = path, data = default_data() }, State)
    local content = FS.read_file(path)
    if content and content ~= "" then
        local ok, decoded = pcall(JSON.decode, content)
        if ok then
            self.data = ensure_shape(decoded)
        end
    end
    return self
end

function State:save()
    self.data.version = 1
    return FS.write_file(self.path, JSON.encode(self.data))
end

function State:set_status(module_name, ok, message)
    local bucket = self.data[module_name]
    if not bucket then return end
    bucket.last_sync = os.time()
    bucket.last_error = ok and nil or message
end

return State
