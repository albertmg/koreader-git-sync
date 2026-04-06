--[[--
Sync a KOReader library with a single Git provider repository containing:

    /books
    /meta
    /config

The plugin deliberately uses provider HTTP APIs instead of shelling out to git,
so it can run on PocketBook, Kindle, and Android KOReader builds.
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local BooksSync = require("gls_books_sync")
local ConfigSync = require("gls_config_sync")
local MetaSync = require("gls_meta_sync")
local Provider = require("gls_provider")
local Settings = require("gls_settings")
local State = require("gls_state")

local GitLibrarySync = WidgetContainer:extend{
    name = "gitlibrarysync",
    is_doc_only = false,
}

local function yes_no(value)
    return value and _("enabled") or _("disabled")
end

local function time_text(value)
    if not value then return _("never") end
    return os.date("%Y-%m-%d %H:%M", value)
end

local function format_counts(counts)
    if not counts then return "" end
    if counts.skipped then return counts.message or _("skipped") end
    local parts = {}
    local order = {
        "downloaded",
        "uploaded",
        "deleted",
        "deleted_local",
        "deleted_remote",
        "unchanged",
        "skipped",
    }
    for _, key in ipairs(order) do
        if counts[key] and counts[key] > 0 then
            table.insert(parts, key:gsub("_", " ") .. ": " .. counts[key])
        end
    end
    if #parts == 0 then return _("no changes") end
    return table.concat(parts, ", ")
end

function GitLibrarySync:init()
    self.settings = Settings.open()
    self.state = State.open(self.settings:state_path())
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    if self.settings.data.startup_sync then
        UIManager:scheduleIn(2, function()
            self:syncBooksAndMetadata(true)
        end)
    end
end

function GitLibrarySync:onDispatcherRegisterActions()
    Dispatcher:registerAction("gitlibrarysync_books", {
        category = "none",
        event = "GitLibrarySyncBooks",
        title = _("Sync Git library books"),
        general = true,
    })
    Dispatcher:registerAction("gitlibrarysync_meta", {
        category = "none",
        event = "GitLibrarySyncMetadata",
        title = _("Sync Git library metadata"),
        general = true,
    })
    Dispatcher:registerAction("gitlibrarysync_config", {
        category = "none",
        event = "GitLibrarySyncConfig",
        title = _("Sync Git library config"),
        general = true,
    })
end

function GitLibrarySync:client()
    local cfg = {}
    for k, v in pairs(self.settings.data) do
        cfg[k] = v
    end
    cfg.author_email = self.settings:author_email()
    cfg.provider = Provider.normalize(cfg.provider)
    return Provider.new(cfg)
end

function GitLibrarySync:is_configured(show_error)
    if self.settings:is_configured() then return true end
    if show_error then
        self:show_error(_("Git Library Sync is not configured. Open setup and enter the repository and token."))
    end
    return false
end

function GitLibrarySync:show_error(message)
    UIManager:show(InfoMessage:new{
        text = _("Git Library Sync failed:") .. "\n\n" .. tostring(message),
        icon = "notice-warning",
    })
end

function GitLibrarySync:show_info(message)
    UIManager:show(InfoMessage:new{ text = message })
end

function GitLibrarySync:run_sync(module_name, startup, fn)
    if not self:is_configured(not startup) then
        return false, _("not configured")
    end
    local ok, success, result = pcall(fn)
    if not ok then
        self.state:set_status(module_name, false, success)
        self.state:save()
        self:show_error(success)
        return false, success
    end
    if not success then
        self.state:set_status(module_name, false, result)
        self.state:save()
        self:show_error(result)
        return false, result
    end
    return true, result
end

function GitLibrarySync:sync_books(startup)
    return self:run_sync("books", startup, function()
        return BooksSync.new(self:client(), self.settings, self.state):sync()
    end)
end

function GitLibrarySync:sync_meta(startup)
    return self:run_sync("meta", startup, function()
        return MetaSync.new(self:client(), self.settings, self.state):sync()
    end)
end

function GitLibrarySync:syncBooksAndMetadata(startup)
    if not self:is_configured(not startup) then return true end
    local books_ok, books_result = self:sync_books(startup)
    local meta_ok, meta_result = self:sync_meta(startup)
    if not startup and books_ok and meta_ok then
        self:show_info(_("Books and metadata sync complete.") .. "\n\n"
            .. _("Books") .. ": " .. format_counts(books_result) .. "\n"
            .. _("Metadata") .. ": " .. format_counts(meta_result))
    end
    return books_ok and meta_ok
end

function GitLibrarySync:onGitLibrarySyncBooks()
    local ok, result = self:sync_books(false)
    if ok then
        self:show_info(_("Books sync complete.") .. "\n\n" .. format_counts(result))
    end
    return true
end

function GitLibrarySync:onGitLibrarySyncMetadata()
    local ok, result = self:sync_meta(false)
    if ok then
        self:show_info(_("Metadata sync complete.") .. "\n\n" .. format_counts(result))
    end
    return true
end

function GitLibrarySync:onGitLibrarySyncBooksAndMetadata()
    self:syncBooksAndMetadata(false)
    return true
end

function GitLibrarySync:onGitLibrarySyncConfig()
    if not self:is_configured(true) then return true end
    local sync = ConfigSync.new(self:client(), self.settings, self.state)
    local ok, plan_or_err = sync:prepare()
    if not ok then
        self.state:set_status("config", false, plan_or_err)
        self.state:save()
        self:show_error(plan_or_err)
        return true
    end
    if plan_or_err.skipped then
        self:show_info(plan_or_err.message or _("Config sync skipped."))
        return true
    end
    if #plan_or_err.conflicts == 0 then
        self:finish_config_sync(sync, plan_or_err, {})
    else
        self:resolve_config_conflicts(sync, plan_or_err, 1, {})
    end
    return true
end

function GitLibrarySync:resolve_config_conflicts(sync, plan, index, choices)
    local conflict = plan.conflicts[index]
    if not conflict then
        self:finish_config_sync(sync, plan, choices)
        return
    end

    local function continue_with(choice)
        choices[conflict.rel] = choice
        UIManager:scheduleIn(0, function()
            self:resolve_config_conflicts(sync, plan, index + 1, choices)
        end)
    end

    local text = _("Configuration conflict:") .. "\n\n" .. conflict.rel .. "\n\n"
        .. _("Choose which version should win. Skipping leaves this file unchanged.")
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Use local"),
        ok_callback = function()
            continue_with("local")
        end,
        cancel_text = _("Skip"),
        cancel_callback = function()
            continue_with("skip")
        end,
        other_buttons = {{
            {
                text = _("Use remote"),
                callback = function()
                    continue_with("remote")
                end,
            },
        }},
    })
end

function GitLibrarySync:finish_config_sync(sync, plan, choices)
    local ok, result = sync:apply(plan, choices)
    if not ok then
        self.state:set_status("config", false, result)
        self.state:save()
        self:show_error(result)
        return
    end
    self:show_info(_("Config sync complete.") .. "\n\n" .. format_counts(result))
end

function GitLibrarySync:show_status()
    local cfg = self.settings.data
    local data = self.state.data
    local repo = cfg.repository ~= "" and cfg.repository or _("not set")
    local text = _("Git Library Sync") .. "\n\n"
        .. _("Provider") .. ": " .. Provider.label(cfg.provider) .. "\n"
        .. _("Repository") .. ": " .. repo .. "\n"
        .. _("API URL") .. ": " .. (cfg.base_url or Provider.default_base_url(cfg.provider)) .. "\n"
        .. _("Device") .. ": " .. (cfg.device_name or "") .. "\n"
        .. _("Books folder") .. ": " .. (cfg.books_dir or "") .. "\n"
        .. _("Config folder") .. ": " .. (cfg.config_dir or "") .. "\n\n"
        .. _("Books") .. ": " .. yes_no(cfg.books_enabled) .. ", " .. _("last sync") .. ": " .. time_text(data.books.last_sync) .. "\n"
        .. _("Metadata") .. ": " .. yes_no(cfg.meta_enabled) .. ", " .. _("last sync") .. ": " .. time_text(data.meta.last_sync) .. "\n"
        .. _("Config") .. ": " .. yes_no(cfg.config_enabled) .. ", " .. _("last sync") .. ": " .. time_text(data.config.last_sync)
    self:show_info(text)
end

function GitLibrarySync:show_setup(touchmenu_instance)
    local cfg = self.settings.data
    local dialog
    local current_provider = Provider.normalize(cfg.provider)
    dialog = MultiInputDialog:new{
        title = _("Git Library Sync setup"),
        fields = {
            {
                description = _("Provider: gitlab or github"),
                text = current_provider,
                hint = "gitlab",
            },
            {
                description = _("Provider API/base URL"),
                text = cfg.base_url or Provider.default_base_url(current_provider),
                hint = Provider.default_base_url(current_provider),
            },
            {
                description = _("Repository path or URL"),
                text = cfg.repository or "",
                hint = "owner/repository",
            },
            {
                description = _("Provider username"),
                text = cfg.username or "",
                hint = _("username"),
            },
            {
                description = _("HTTPS access token"),
                text = cfg.token or "",
                text_type = "password",
                hint = _("token"),
            },
            {
                description = _("Device name used for commits"),
                text = cfg.device_name or "",
                hint = "kindle-oasis",
            },
            {
                description = _("Local books folder managed by this plugin"),
                text = cfg.books_dir or "",
                hint = "/mnt/us/documents/git-library",
            },
            {
                description = _("Local KOReader configuration folder"),
                text = cfg.config_dir or "",
                hint = _("settings folder"),
            },
        },
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local new_provider = Provider.normalize(fields[1])
                    local new_base_url = fields[2]
                    if new_provider ~= current_provider
                            and (new_base_url == "" or new_base_url == Provider.default_base_url(current_provider)) then
                        new_base_url = Provider.default_base_url(new_provider)
                    end
                    cfg.provider = new_provider
                    cfg.base_url = new_base_url
                    cfg.repository = fields[3]
                    cfg.username = fields[4]
                    cfg.token = fields[5]
                    cfg.device_name = fields[6]
                    cfg.books_dir = fields[7]
                    cfg.config_dir = fields[8]
                    self.settings:save()
                    UIManager:close(dialog)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function GitLibrarySync:addToMainMenu(menu_items)
    menu_items.gitlibrarysync = {
        text = _("Git Library Sync"),
        sub_item_table = {
            {
                text = _("Status"),
                keep_menu_open = true,
                callback = function()
                    self:show_status()
                end,
            },
            {
                text = _("Setup"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:show_setup(touchmenu_instance)
                end,
                separator = true,
            },
            {
                text_func = function()
                    return _("Provider") .. ": " .. Provider.label(self.settings.data.provider)
                end,
                keep_menu_open = true,
                sub_item_table = {
                    {
                        text = "GitLab",
                        radio = true,
                        checked_func = function()
                            return Provider.normalize(self.settings.data.provider) == "gitlab"
                        end,
                        callback = function()
                            local current = Provider.normalize(self.settings.data.provider)
                            if current ~= "gitlab" then
                                local old_default = Provider.default_base_url(current)
                                self.settings.data.provider = "gitlab"
                                if self.settings.data.base_url == "" or self.settings.data.base_url == old_default then
                                    self.settings.data.base_url = Provider.default_base_url("gitlab")
                                end
                                self.settings:save()
                            end
                        end,
                    },
                    {
                        text = "GitHub",
                        radio = true,
                        checked_func = function()
                            return Provider.normalize(self.settings.data.provider) == "github"
                        end,
                        callback = function()
                            local current = Provider.normalize(self.settings.data.provider)
                            if current ~= "github" then
                                local old_default = Provider.default_base_url(current)
                                self.settings.data.provider = "github"
                                if self.settings.data.base_url == "" or self.settings.data.base_url == old_default then
                                    self.settings.data.base_url = Provider.default_base_url("github")
                                end
                                self.settings:save()
                            end
                        end,
                    },
                },
            },
            {
                text = _("Sync books"),
                keep_menu_open = true,
                callback = function()
                    self:onGitLibrarySyncBooks()
                end,
            },
            {
                text = _("Sync metadata"),
                keep_menu_open = true,
                callback = function()
                    self:onGitLibrarySyncMetadata()
                end,
            },
            {
                text = _("Sync books + metadata"),
                keep_menu_open = true,
                callback = function()
                    self:onGitLibrarySyncBooksAndMetadata()
                end,
            },
            {
                text = _("Sync config"),
                keep_menu_open = true,
                callback = function()
                    self:onGitLibrarySyncConfig()
                end,
                separator = true,
            },
            {
                text = _("Enable books sync"),
                keep_menu_open = true,
                checked_func = function()
                    return self.settings.data.books_enabled
                end,
                callback = function()
                    self.settings.data.books_enabled = not self.settings.data.books_enabled
                    self.settings:save()
                end,
            },
            {
                text = _("Enable metadata sync"),
                keep_menu_open = true,
                checked_func = function()
                    return self.settings.data.meta_enabled
                end,
                callback = function()
                    self.settings.data.meta_enabled = not self.settings.data.meta_enabled
                    self.settings:save()
                end,
            },
            {
                text = _("Enable config sync"),
                keep_menu_open = true,
                checked_func = function()
                    return self.settings.data.config_enabled
                end,
                callback = function()
                    self.settings.data.config_enabled = not self.settings.data.config_enabled
                    self.settings:save()
                end,
            },
            {
                text = _("Run automatic startup sync"),
                keep_menu_open = true,
                checked_func = function()
                    return self.settings.data.startup_sync
                end,
                callback = function()
                    self.settings.data.startup_sync = not self.settings.data.startup_sync
                    self.settings:save()
                end,
            },
        },
    }
end

return GitLibrarySync
