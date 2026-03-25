local JSON = require("json")
local ltn12 = require("ltn12")
local socket = require("socket")

local ok_http, http = pcall(require, "socket.http")
local ok_https, https = pcall(require, "ssl.https")
local ok_socketutil, socketutil = pcall(require, "socketutil")

if not ok_http then
    error("Git Library Sync requires LuaSocket")
end

local GitLab = {}
GitLab.__index = GitLab

local function trim_right_slash(s)
    return tostring(s or ""):gsub("/+$", "")
end

local function urlencode(s)
    s = tostring(s or "")
    return (s:gsub("([^%w%-%_%.%~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function parse_repository(repository, base_url)
    repository = tostring(repository or ""):gsub("%s+", "")
    base_url = trim_right_slash(base_url or "https://gitlab.com")
    local project_path = repository

    local scheme, host, path = repository:match("^(https?)://([^/]+)/(.+)$")
    if scheme and host and path then
        base_url = scheme .. "://" .. host
        project_path = path
    else
        host, path = repository:match("^git@([^:]+):(.+)$")
        if host and path then
            base_url = "https://" .. host
            project_path = path
        end
    end

    project_path = project_path:gsub("^/+", ""):gsub("/+$", ""):gsub("%.git$", "")
    return base_url, project_path
end

local function transport_for(url)
    if url:match("^https://") and ok_https then
        return https
    end
    return http
end

function GitLab.new(settings)
    local base_url, project_path = parse_repository(settings.repository, settings.base_url)
    return setmetatable({
        base_url = base_url,
        project_path = project_path,
        token = settings.token,
        username = settings.username,
        device_name = settings.device_name or "koreader-device",
        author_email = settings.author_email,
        block_timeout = settings.block_timeout or 20,
        total_timeout = settings.total_timeout or 120,
        branch = settings.branch,
        project = nil,
    }, GitLab)
end

function GitLab.urlencode(s)
    return urlencode(s)
end

function GitLab:project_id()
    return urlencode(self.project_path)
end

function GitLab:api_url(path)
    return self.base_url .. "/api/v4" .. path
end

function GitLab:request(method, url, opts)
    opts = opts or {}
    local sink = {}
    local headers = {
        ["Accept"] = opts.accept or "application/json",
    }
    if self.token and self.token ~= "" then
        headers["PRIVATE-TOKEN"] = self.token
    end
    if opts.headers then
        for k, v in pairs(opts.headers) do
            headers[k] = v
        end
    end

    local body = opts.body
    if opts.json then
        body = JSON.encode(opts.json)
        headers["Content-Type"] = "application/json"
    end
    if body then
        headers["Content-Length"] = tostring(#body)
    end

    local request = {
        method = method,
        url = url,
        headers = headers,
    }

    if body then
        request.source = ltn12.source.string(body)
    end
    if opts.file_path then
        local fh, err = io.open(opts.file_path, "wb")
        if not fh then return nil, "Cannot write download: " .. tostring(err) end
        request.sink = ltn12.sink.file(fh)
    else
        request.sink = ltn12.sink.table(sink)
    end

    if ok_socketutil then
        socketutil:set_timeout(self.block_timeout, self.total_timeout)
    end
    local ok, r1, r2, r3, r4 = pcall(transport_for(url).request, request)
    if ok_socketutil then
        socketutil:reset_timeout()
    end
    if not ok then
        if opts.file_path then os.remove(opts.file_path) end
        return nil, "Network error: " .. tostring(r1)
    end

    local code, response_headers, status = socket.skip(1, r1, r2, r3, r4)
    local response_body = table.concat(sink)
    code = tonumber(code)
    if not code then
        if opts.file_path then os.remove(opts.file_path) end
        return nil, "Network error: " .. tostring(status or response_body)
    end
    if code < 200 or code >= 300 then
        if opts.file_path then os.remove(opts.file_path) end
        return nil, string.format("GitLab HTTP %d: %s", code, response_body ~= "" and response_body or tostring(status))
    end
    if opts.file_path then
        return true, response_headers, code
    end
    if response_body == "" then
        return true, response_headers, code
    end
    if opts.raw then
        return response_body, response_headers, code
    end
    local decoded_ok, decoded = pcall(JSON.decode, response_body)
    if not decoded_ok then
        return nil, "GitLab returned invalid JSON"
    end
    return decoded, response_headers, code
end

function GitLab:api(method, path, opts)
    return self:request(method, self:api_url(path), opts)
end

function GitLab:ensure_project()
    if self.project then return true end
    if not self.project_path or self.project_path == "" then
        return nil, "Repository is not configured"
    end
    local project, err = self:api("GET", "/projects/" .. self:project_id())
    if not project then return nil, err end
    self.project = project
    self.branch = self.branch or project.default_branch or "main"
    return true
end

function GitLab:list_files(prefix)
    local ok, err = self:ensure_project()
    if not ok then return nil, err end
    prefix = tostring(prefix or "")
    local files = {}
    local page = 1
    while true do
        local path = "/projects/" .. self:project_id()
            .. "/repository/tree?recursive=true&per_page=100&page=" .. page
            .. "&ref=" .. urlencode(self.branch)
        if prefix ~= "" then
            path = path .. "&path=" .. urlencode(prefix)
        end
        local result, headers
        result, headers, err = self:api("GET", path)
        if not result then
            if tostring(headers):match("HTTP 404") then
                return files
            end
            return nil, headers
        end
        for _, item in ipairs(result) do
            if item.type == "blob" then
                files[item.path] = item
            end
        end
        local next_page = headers and (headers["x-next-page"] or headers["X-Next-Page"])
        if not next_page or next_page == "" then break end
        page = tonumber(next_page)
        if not page then break end
    end
    return files
end

function GitLab:get_raw(remote_path)
    local ok, err = self:ensure_project()
    if not ok then return nil, err end
    return self:api("GET",
        "/projects/" .. self:project_id()
            .. "/repository/files/" .. urlencode(remote_path)
            .. "/raw?ref=" .. urlencode(self.branch),
        { raw = true, accept = "*/*" })
end

function GitLab:download_file(remote_path, local_path)
    local ok, err = self:ensure_project()
    if not ok then return nil, err end
    return self:api("GET",
        "/projects/" .. self:project_id()
            .. "/repository/files/" .. urlencode(remote_path)
            .. "/raw?ref=" .. urlencode(self.branch),
        { file_path = local_path, accept = "*/*" })
end

function GitLab:commit(actions, message)
    local ok, err = self:ensure_project()
    if not ok then return nil, err end
    if #actions == 0 then return true end
    local payload = {
        branch = self.branch,
        commit_message = message,
        author_name = self.device_name,
        author_email = self.author_email,
        actions = actions,
    }
    return self:api("POST",
        "/projects/" .. self:project_id() .. "/repository/commits",
        { json = payload })
end

return GitLab
