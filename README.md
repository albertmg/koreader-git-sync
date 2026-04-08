# Git Library Sync: Git-backed Library Sync for KOReader

Git Library Sync keeps a KOReader library aligned with a single Git provider
repository. It can pull books onto the device, sync reading metadata, and
manually sync KOReader configuration without requiring a `git` binary on the
reader.

The repository must use this fixed layout:

```text
/books
/meta
/config
```

## Features

- **One repository**: Books, reading metadata, and configuration live in one
  repository with predictable folders.
- **GitLab and GitHub providers**: Select `gitlab` or `github` in the plugin
  settings. Self-hosted GitLab and GitHub Enterprise can be used with custom API
  URLs.
- **No external git dependency**: The plugin uses provider HTTP APIs, so it can
  run on PocketBook, Kindle, and Android KOReader builds.
- **Remote-master books sync**: `/books` is the source of truth. Books are
  downloaded to the configured local folder and are never pushed back.
- **Automatic metadata sync**: `/meta` syncs on startup and manually. When both
  sides changed a metadata file, the newest mtime wins; ties prefer local.
- **Manual config sync**: `/config` only syncs when requested. Conflicts prompt
  for local, remote, or skip.
- **Visible failures**: Sync errors are surfaced in KOReader instead of failing
  silently.

## Basic Requirements

- [KOReader](https://github.com/koreader/koreader) installed on the device
- A GitLab or GitHub repository with `/books`, `/meta`, and `/config`
- A provider access token with read/write access to the repository
- Network access from KOReader

## Getting Started

### 1. Prepare the Repository

Create a repository with this structure:

```text
books/
meta/
config/
```

Put your book files under `books/`. The `meta/` and `config/` folders may start
empty; the plugin creates `.gitlibrarysync-manifest.json` files there as needed.

### 2. Install the Plugin

Copy the `gitlibrarysync.koplugin` folder into KOReader's `plugins` directory,
then restart KOReader.

Typical destination:

```text
koreader/plugins/gitlibrarysync.koplugin
```

### 3. Configure the Plugin

Open KOReader, then go to:

```text
Tools > More tools > Git Library Sync > Setup
```

Fill in:

- **Provider**: `gitlab` or `github`
- **Provider API/base URL**:
  - GitLab.com: `https://gitlab.com`
  - GitHub.com: `https://api.github.com`
  - GitHub Enterprise: `https://github.example.com/api/v3`
- **Repository path or URL**:
  - GitLab: `group/project`
  - GitHub: `owner/repository`
- **Provider username**
- **HTTPS access token**
- **Device name** used for commit author identity
- **Local books folder** managed by this plugin
- **Local KOReader configuration folder**

Credentials are stored locally in `gitlibrarysync.lua`. That file is excluded
from config sync by default.

### 4. Use the Plugin

Available menu actions:

- **Status**: Show provider, repository, folders, and last sync times.
- **Sync books**: Pull `/books` from the remote repository.
- **Sync metadata**: Push/pull reading metadata under `/meta`.
- **Sync books + metadata**: Run both automatic sync modules manually.
- **Sync config**: Manually push/pull `/config`, prompting on conflicts.
- **Provider**: Switch between GitLab and GitHub.
- **Enable books sync / Enable metadata sync / Run automatic startup sync**:
  Control startup behavior.

Books and metadata sync automatically on startup when enabled. Config sync never
runs automatically.

## Provider Notes

- GitLab uses the GitLab REST API and creates one commit for each sync batch.
- GitHub uses the GitHub REST API Contents endpoints. A sync batch may become
  multiple remote commits, one per changed file.
- Both providers behave like "commit and push" from the user's perspective:
  once the API call succeeds, the remote repository has been updated.

## Sync Rules

- `/books`: Remote wins. Local book additions or edits in the managed books
  folder are not pushed.
- `/meta`: Bidirectional. The newest file wins; equal mtimes prefer local.
- `/config`: Bidirectional and manual. Conflicts prompt for local, remote, or
  skip.
- Sensitive config paths are excluded by default, including token, password,
  secret, credential, cookie, session, network, device, cache, and log files.

## Packaging

Build deliverable archives from the repository root:

```sh
make package
```

This creates:

```text
dist/gitlibrarysync.koplugin.zip
dist/gitlibrarysync.koplugin.tar.gz
```

The zip is the normal installable package: extract or copy it so the device has
`koreader/plugins/gitlibrarysync.koplugin`.

Clean generated packages:

```sh
make clean
```

## Development Checks

Run local checks from the repository root:

```sh
luac -p gitlibrarysync.koplugin/*.lua
lua -e 'package.path="gitlibrarysync.koplugin/?.lua;"..package.path; local Path=require("gls_path"); assert(Path.join("/a/","b","c") == "/a/b/c"); local Base64=require("gls_base64"); assert(Base64.encode("hello") == "aGVsbG8="); local Hash=require("gls_hash"); assert(Hash.content("abc") == Hash.content("abc")); assert(Hash.content("abc") ~= Hash.content("abd")); print("ok - lua pure module smoke tests")'
python3 tests/test_static_contract.py
```

## Safety Notes

- Use a dedicated local books folder. Books sync can delete local files in that
  folder when they do not exist under remote `/books`.
- KOReader `.sdr` sidecar folders are excluded from books cleanup and handled by
  metadata sync.
- The config exclusion list is filename/path based. It prevents obvious secrets
  from syncing, but it does not redact secrets embedded inside arbitrary config
  files.
