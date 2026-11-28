# Folio developer commands. Run `make help` for the list.
.DEFAULT_GOAL := help
CLT_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
# Command Line Tools ship Swift Testing outside the default search path; Xcode doesn't need this.
TEST_FLAGS := $(if $(wildcard $(CLT_FRAMEWORKS)/Testing.framework),-Xswiftc -F$(CLT_FRAMEWORKS) -Xlinker -F$(CLT_FRAMEWORKS) -Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS),)

.PHONY: help build app run test lint clean launch-time mcp-check bench site-data brand

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Compile all modules (debug)
	swift build

app: ## Build build/Folio.app (release)
	scripts/bundle.sh release

run: ## Build a debug app and open it
	scripts/bundle.sh debug && open build/Folio.app

test: ## Run every test suite
	swift test $(TEST_FLAGS)

lint: ## Check formatting (needs swift-format, bundled with Swift 6)
	swift format lint --recursive --strict Sources Tests Package.swift

launch-time: app ## Measure cold launch to first window
	scripts/launch-time.sh

mcp-check: ## Check `folio mcp` answers initialize and tools/list in under 100 ms
	swift build --product folio-cli
	@# Warm-up: macOS scans a freshly linked binary on its first launch, which installed copies never pay.
	@"$$(swift build --show-bin-path)/folio-cli" --version >/dev/null
	@python3 -c "$$MCP_CHECK" "$$(swift build --show-bin-path)/folio-cli"

bench: app ## Time Folio against sips, afconvert and avconvert; writes site/bench.json
	scripts/bench.sh

site-data: app ## Regenerate site/formats.json from `folio formats`
	scripts/site-data.sh

brand: ## Copy brand/ assets into the website and regenerate the app icon
	mkdir -p site/brand/assets && cp brand/logo/*.svg brand/document-icon.svg site/brand/assets/
	cp brand/logo/folio-mark.svg site/favicon.svg
	rm -f build/AppIcon.icns

clean: ## Remove build products
	rm -rf .build build

# Cold-starts the MCP server, sends initialize and tools/list, and times each reply.
define MCP_CHECK
import json, subprocess, sys, time
start = time.perf_counter()
p = subprocess.Popen([sys.argv[1], "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def ask(id, method, params=None):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": id, "method": method, "params": params or {}}) + "\n")
    p.stdin.flush()
    reply = json.loads(p.stdout.readline())
    assert reply.get("id") == id and "result" in reply, reply
    return reply["result"], (time.perf_counter() - start) * 1000
init, t1 = ask(1, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "make", "version": "1"}})
tools, t2 = ask(2, "tools/list")
p.stdin.close()
p.wait(timeout=5)
names = [t["name"] for t in tools["tools"]]
print(f"initialize {t1:.1f} ms, tools/list {t2:.1f} ms after launch; {len(names)} tools: {', '.join(names)}")
assert init["protocolVersion"] == "2025-11-25", init
assert len(names) == 6, names
assert t1 < 100, f"initialize took {t1:.1f} ms (limit 100)"
endef
export MCP_CHECK
