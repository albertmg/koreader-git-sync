local GitHub = require("gls_github")
local GitLab = require("gls_gitlab")

local Provider = {}

local labels = {
    github = "GitHub",
    gitlab = "GitLab",
}

local defaults = {
    github = "https://api.github.com",
    gitlab = "https://gitlab.com",
}

function Provider.normalize(provider)
    provider = tostring(provider or "gitlab"):lower()
    provider = provider:gsub("%s+", "")
    if provider == "github" or provider == "gh" then return "github" end
    return "gitlab"
end

function Provider.label(provider)
    return labels[Provider.normalize(provider)]
end

function Provider.default_base_url(provider)
    return defaults[Provider.normalize(provider)]
end

function Provider.new(settings)
    local provider = Provider.normalize(settings.provider)
    if provider == "github" then
        return GitHub.new(settings)
    end
    return GitLab.new(settings)
end

return Provider
