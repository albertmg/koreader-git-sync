local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local Device = require("device")

local FS = require("gls_fs")
local Path = require("gls_path")

local Settings = {}
Settings.__index = Settings

local function device_name()
    local name = Device.model or Device.device or os.getenv("HOSTNAME") or "koreader-device"
    name = tostring(name):gsub("%s+", "-"):gsub("[^%w%._%-]", ""):lower()
    if name == "" then name = "koreader-device" end
    return name
end

local function settings_dir()
    if DataStorage.getSettingsDir then
        return DataStorage:getSettingsDir()
    end
    return DataStorage:getDataDir()
end

local function defaults()
    local data_dir = DataStorage:getDataDir()
    return {
        provider = "gitlab",
        base_url = "https://gitlab.com",
        repository = "",
        username = "",
        token = "",
        device_name = device_name(),
        books_dir = Path.join(data_dir, "git-library-books"),
        config_dir = settings_dir(),
        books_enabled = true,
        meta_enabled = true,
        config_enabled = true,
        startup_sync = true,
        block_timeout = 20,
        total_timeout = 120,
    }
end

local function merge_defaults(data)
    local merged = defaults()
    for k, v in pairs(data or {}) do
        merged[k] = v
    end
    return merged
end

function Settings.open()
    local dir = settings_dir()
    FS.ensure_dir(dir)
    local file_path = Path.join(dir, "gitlibrarysync.lua")
    local store = LuaSettings:open(file_path)
    store.data = merge_defaults(store.data)
    local self = setmetatable({ path = file_path, store = store, data = store.data }, Settings)
    return self
end

function Settings:save()
    self.store.data = merge_defaults(self.data)
    self.data = self.store.data
    self.store:flush()
end

function Settings:is_configured()
    return self.data.repository ~= nil and self.data.repository ~= ""
        and self.data.token ~= nil and self.data.token ~= ""
        and self.data.books_dir ~= nil and self.data.books_dir ~= ""
end

function Settings:state_path()
    local dir = Path.join(DataStorage:getDataDir(), "gitlibrarysync")
    FS.ensure_dir(dir)
    return Path.join(dir, "state.json")
end

function Settings:author_email()
    local name = self.data.device_name or device_name()
    name = tostring(name):gsub("%s+", "-"):gsub("[^%w%._%-]", ""):lower()
    if name == "" then name = "koreader-device" end
    return name .. "@koreader.local"
end

return Settings
