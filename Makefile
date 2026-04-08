PLUGIN := gitlibrarysync.koplugin
DIST := dist
ZIP := $(DIST)/$(PLUGIN).zip
TARBALL := $(DIST)/$(PLUGIN).tar.gz

.PHONY: package clean check

package:
	@mkdir -p $(DIST)
	@rm -f $(ZIP) $(TARBALL)
	@zip -qr $(ZIP) $(PLUGIN) \
		-x '*/.DS_Store' \
		-x '*/__pycache__/*' \
		-x '*.luac' \
		-x '*.tmp' \
		-x '*.log'
	@tar --exclude='.DS_Store' \
		--exclude='__pycache__' \
		--exclude='*.luac' \
		--exclude='*.tmp' \
		--exclude='*.log' \
		-czf $(TARBALL) $(PLUGIN)
	@printf 'Created %s\nCreated %s\n' "$(ZIP)" "$(TARBALL)"

check:
	@luac -p $(PLUGIN)/*.lua
	@lua -e 'package.path="$(PLUGIN)/?.lua;"..package.path; local Path=require("gls_path"); assert(Path.join("/a/","b","c") == "/a/b/c"); local Base64=require("gls_base64"); assert(Base64.encode("hello") == "aGVsbG8="); local Hash=require("gls_hash"); assert(Hash.content("abc") == Hash.content("abc")); assert(Hash.content("abc") ~= Hash.content("abd")); print("ok - lua pure module smoke tests")'
	@python3 tests/test_static_contract.py

clean:
	@rm -rf $(DIST)
