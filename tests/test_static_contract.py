from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "koreader-git-sync.koplugin"


def read(name: str) -> str:
    return (PLUGIN / name).read_text()


def test_plugin_structure_exists():
    expected = {
        "_meta.lua",
        "main.lua",
        "gls_gitlab.lua",
        "gls_github.lua",
        "gls_provider.lua",
        "gls_base64.lua",
        "gls_books_sync.lua",
        "gls_meta_sync.lua",
        "gls_config_sync.lua",
        "gls_settings.lua",
        "gls_state.lua",
    }
    assert expected.issubset({path.name for path in PLUGIN.iterdir()})


def test_uses_provider_apis_without_shelling_out_to_git():
    combined = "\n".join(path.read_text() for path in PLUGIN.glob("*.lua"))
    assert "/api/v4" in read("gls_gitlab.lua")
    assert "/repository/commits" in read("gls_gitlab.lua")
    assert "api.github.com" in read("gls_github.lua")
    assert "/contents/" in read("gls_github.lua")
    assert "Authorization" in read("gls_github.lua")
    assert "gls_provider" in read("main.lua")
    assert "os.execute" not in combined
    assert "git " not in combined


def test_provider_can_be_selected_in_settings_and_ui():
    settings = read("gls_settings.lua")
    provider = read("gls_provider.lua")
    main = read("main.lua")
    assert 'provider = "gitlab"' in settings
    assert 'return "github"' in provider
    assert "Provider.label" in main
    assert "GitHub" in main
    assert "GitLab" in main


def test_project_name_is_koreader_git_sync():
    meta = read("_meta.lua")
    main = read("main.lua")
    assert "KOReader Git Sync" in meta
    assert "KOReader Git Sync" in main
    assert PLUGIN.name == "koreader-git-sync.koplugin"


def test_books_sync_is_remote_master_only():
    books = read("gls_books_sync.lua")
    assert 'list_files("books")' in books
    assert "download_file(remote_path" in books
    assert "remove_file" in books
    assert ":commit(" not in books


def test_metadata_newest_wins_and_local_tie_breaker():
    meta = read("gls_meta_sync.lua")
    assert "local_file.mtime >= remote_mtime" in meta
    assert 'file_path = "meta/" .. rel' in meta
    assert "deleted_remote" in meta
    assert ".koreader-git-sync-manifest.json" in meta


def test_config_is_manual_and_conflict_prompted():
    main = read("main.lua")
    config = read("gls_config_sync.lua")
    assert "syncBooksAndMetadata(true)" in main
    assert "onGitLibrarySyncConfig" in main
    assert "Use local" in main
    assert "Use remote" in main
    assert "Skip" in main
    assert "conflicts" in config


def test_credentials_and_sensitive_config_are_excluded():
    settings = read("gls_settings.lua")
    config = read("gls_config_sync.lua")
    assert "koreader_git_sync.lua" in settings
    for word in ["token", "password", "secret", "credential", "network", "device"]:
        assert word in config


if __name__ == "__main__":
    tests = [
        value
        for name, value in sorted(globals().items())
        if name.startswith("test_") and callable(value)
    ]
    for test in tests:
        test()
        print(f"ok - {test.__name__}")
