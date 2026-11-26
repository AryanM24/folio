# Folio developer commands. Run `make help` for the list.
.DEFAULT_GOAL := help
CLT_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
# Command Line Tools ship Swift Testing outside the default search path; Xcode doesn't need this.
TEST_FLAGS := $(if $(wildcard $(CLT_FRAMEWORKS)/Testing.framework),-Xswiftc -F$(CLT_FRAMEWORKS) -Xlinker -F$(CLT_FRAMEWORKS) -Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS),)

.PHONY: help build app run test lint clean launch-time

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

clean: ## Remove build products
	rm -rf .build build
