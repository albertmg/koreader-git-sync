local JSON = require("json")
local ltn12 = require("ltn12")
local socket = require("socket")

local ok_http, http = pcall(require, "socket.http")
local ok_https, https = pcall(require, "ssl.https")
local ok_socketutil, socketutil = pcall(require, "socketutil")

if not ok_http then
    error("KOReader Git Sync requires LuaSocket")
end

local Base64 = require("gls_base64")
local FS = require("gls_fs")

local GitHub = {}
GitHub.__index = GitHub

local function trim_right_slash(s)
    return tostring(s or ""):gsub("/+$", "")
end

local function urlencode(s)
    s = tostring(s or "")
    return (s:gsub("([^%w%-%_%.%~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function urlencode_path(path)
    local parts = {}
    for part in tostring(path or ""):gmatch("[^/]+") do
        table.insert(parts, urlencode(part))
    end
    return table.concat(parts, "/")
end

local function normalize_api_base(base_url, scheme, host)
    base_url = tostring(base_url or "")
    if base_url == "" or base_url == "https://gitlab.com" then
        if host and host ~= "" and host ~= "github.com" then
            return (scheme or "https") .. "://" .. host .. "/api/v3"
        end
        return "https://api.github.com"
    end

    base_url = trim_right_slash(base_url)
    if base_url == "https://github.com" or base_url == "http://github.com" then
        return "https://api.github.com"
    end
    if base_url:match("^https?://api%.github%.com") then
        return base_url
    end
    if not base_url:match("/api/v3$") then
        local bare_host = base_url:match("^https?://[^/]+$")
        if bare_host then
            base_url = base_url .. "/api/v3"
        end
    end
    return base_url
end

local function parse_repository(repository, base_url)
    repository = tostring(repository or ""):gsub("%s+", "")
    local owner_repo = repository
    local api_base = nil

    local scheme, host, path = repository:match("^(https?)://([^/]+)/(.+)$")
    if scheme and host and path then
        owner_repo = path
        api_base = normalize_api_base(base_url, scheme, host)
    else
        host, path = repository:match("^git@([^:]+):(.+)$")
        if host and path then
            owner_repo = path
            api_base = normalize_api_base(base_url, "https", host)
        end
    end

    api_base = api_base or normalize_api_base(base_url)
    owner_repo = owner_repo:gsub("^/+", ""):gsub("/+$", ""):gsub("%.git$", "")
    local owner, repo = owner_repo:match("^([^/]+)/([^/]+)")
    if repo then repo = repo:gsub("%.git$", "") end
    return api_base, owner, repo
end

local function transport_for(url)
    if url:match("^https://") and ok_https then
        return https
    end
    return http
end

function GitHub.new(settings)
    local base_url, owner, repo = parse_repository(settings.repository, settings.base_url)
    return setmetatable({
        base_url = base_url,
        owner = owner,
        repo = repo,
        token = settings.token,
        username = settings.username,
        device_name = settings.device_name or "koreader-device",
        author_email = settings.author_email,
        block_timeout = settings.block_timeout or 20,
        total_timeout = settings.total_timeout or 120,
        branch = settings.branch,
        repository = nil,
    }, GitHub)
end

function GitHub:repo_id()
    if not self.owner or not self.repo then return nil end
    return urlencode(self.owner) .. "/" .. urlencode(self.repo)
end

function GitHub:api_url(path)
    return self.base_url .. path
end

function GitHub:request(method, url, opts)
    opts = opts or {}
    local sink = {}
    local headers = {
        ["Accept"] = opts.accept or "application/vnd.github+json",
        ["X-GitHub-Api-Version"] = "2022-11-28",
        ["User-Agent"] = "KOReader-Git-Sync",
    }
    if self.token and self.token ~= "" then
        headers["Authorization"] = "Bearer " .. self.token
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
        return nil, string.format("GitHub HTTP %d: %s", code, response_body ~= "" and response_body or tostring(status))
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
        return nil, "GitHub returned invalid JSON"
    end
    return decoded, response_headers, code
end

function GitHub:api(method, path, opts)
    return self:request(method, self:api_url(path), opts)
end

function GitHub:ensure_repository()
    if self.repository then return true end
    local repo_id = self:repo_id()
    if not repo_id then
        return nil, "Repository must be owner/repo for GitHub"
    end
    local repository, err = self:api("GET", "/repos/" .. repo_id)
    if not repository then return nil, err end
    self.repository = repository
    self.branch = self.branch or repository.default_branch or "main"
    return true
end

function GitHub:get_ref()
    local ok, err = self:ensure_repository()
    if not ok then return nil, err end
    return self:api("GET", "/repos/" .. self:repo_id() .. "/git/ref/heads/" .. urlencode_path(self.branch))
end

function GitHub:list_files(prefix)
    local ref, err = self:get_ref()
    if not ref then return nil, err end
    local tree_sha = ref.object and ref.object.sha
    if not tree_sha then return nil, "GitHub branch ref does not contain a commit SHA" end
    local tree, tree_err = self:api("GET", "/repos/" .. self:repo_id() .. "/git/trees/" .. urlencode(tree_sha) .. "?recursive=1")
    if not tree then return nil, tree_err end
    if tree.truncated then
        return nil, "GitHub tree response was truncated; repository is too large for one recursive API listing"
    end

    prefix = tostring(prefix or ""):gsub("^/+", ""):gsub("/+$", "")
    local files = {}
    for _, item in ipairs(tree.tree or {}) do
        if item.type == "blob" then
            if prefix == "" or item.path == prefix or item.path:sub(1, #prefix + 1) == prefix .. "/" then
                files[item.path] = {
                    path = item.path,
                    type = "blob",
                    id = item.sha,
                    sha = item.sha,
                    size = item.size,
                }
            end
        end
    end
    return files
end

function GitHub:get_raw(remote_path)
    local ok, err = self:ensure_repository()
    if not ok then return nil, err end
    return self:api("GET",
        "/repos/" .. self:repo_id()
            .. "/contents/" .. urlencode_path(remote_path)
            .. "?ref=" .. urlencode(self.branch),
        { raw = true, accept = "application/vnd.github.raw+json" })
end

function GitHub:download_file(remote_path, local_path)
    local ok, err = self:ensure_repository()
    if not ok then return nil, err end
    FS.ensure_parent(local_path)
    return self:api("GET",
        "/repos/" .. self:repo_id()
            .. "/contents/" .. urlencode_path(remote_path)
            .. "?ref=" .. urlencode(self.branch),
        { file_path = local_path, accept = "application/vnd.github.raw+json" })
end

function GitHub:file_info(remote_path)
    local ok, err = self:ensure_repository()
    if not ok then return nil, err end
    return self:api("GET",
        "/repos/" .. self:repo_id()
            .. "/contents/" .. urlencode_path(remote_path)
            .. "?ref=" .. urlencode(self.branch))
end

function GitHub:commit(actions, message)
    local ok, err = self:ensure_repository()
    if not ok then return nil, err end
    if #actions == 0 then return true end

    local author = {
        name = self.device_name,
        email = self.author_email,
    }
    for _, action in ipairs(actions) do
        local path = action.file_path
        local info, info_err = self:file_info(path)
        if not info and not tostring(info_err):match("HTTP 404") then
            return nil, info_err
        end

        if action.action == "delete" then
            if info and info.sha then
                local deleted, delete_err = self:api("DELETE",
                    "/repos/" .. self:repo_id() .. "/contents/" .. urlencode_path(path),
                    { json = {
                        message = message .. " (" .. path .. ")",
                        sha = info.sha,
                        branch = self.branch,
                        committer = author,
                        author = author,
                    } })
                if not deleted then return nil, delete_err end
            end
        else
            local payload = {
                message = message .. " (" .. path .. ")",
                content = Base64.encode(action.content or ""),
                branch = self.branch,
                committer = author,
                author = author,
            }
            if info and info.sha then
                payload.sha = info.sha
            end
            local written, write_err = self:api("PUT",
                "/repos/" .. self:repo_id() .. "/contents/" .. urlencode_path(path),
                { json = payload })
            if not written then return nil, write_err end
        end
    end
    return true
end

return GitHub
