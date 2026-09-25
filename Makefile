APP_NAME := MeetingGuru
APP := dist/$(APP_NAME).app
VERSION ?= 2.0.0
INSTALL_DIR ?= /Applications
STAMP := $(shell date +%Y%m%d-%H%M%S)
FRAMES := .build/demo-frames

.DEFAULT_GOAL := help
.PHONY: help build test lint format app run demo gallery demo-gif install uninstall zip clean

help: ## List the targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Debug build
	swift build

test: ## Run the unit tests
	swift test

lint: ## Check formatting and style
	swift format lint --strict --configuration .swift-format -r Sources Tests

format: ## Reformat the sources in place
	swift format format --configuration .swift-format -i -r Sources Tests

app: ## Build dist/MeetingGuru.app (release, arm64, ad-hoc signed)
	VERSION=$(VERSION) ./scripts/build-app.sh

run: build ## Run from source with debug logging
	.build/debug/$(APP_NAME) --debug

demo: build ## Run with sample meetings and an invite, no calendar needed
	.build/debug/$(APP_NAME) --debug --demo-mode

gallery: build ## Render every island state to dist/gallery/*.png
	.build/debug/$(APP_NAME) --render-gallery dist/gallery

demo-gif: build ## Record docs/images/demo.gif (needs Screen Recording permission and ffmpeg)
	swift scripts/record-demo.swift .build/debug/$(APP_NAME) $(FRAMES) 25
	ffmpeg -loglevel error -y \
		-loop 1 -framerate 25 -i scripts/demo-backdrop.png \
		-framerate 25 -i $(FRAMES)/%05d.png \
		-filter_complex "[0][1]overlay=shortest=1,crop=380:270:60:80,fps=20,split[a][b];[a]palettegen=max_colors=200:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
		docs/images/demo.gif
	@echo "Wrote docs/images/demo.gif"

install: app ## Install into /Applications (INSTALL_DIR=...), old copy to the Trash, then launch
	-@pkill -x $(APP_NAME) && sleep 1 || true
	@if [ -d "$(INSTALL_DIR)/$(APP_NAME).app" ]; then \
		mv "$(INSTALL_DIR)/$(APP_NAME).app" "$(HOME)/.Trash/$(APP_NAME)-$(STAMP).app" && \
		echo "Moved the previous $(APP_NAME).app to the Trash"; \
	fi
	mkdir -p "$(INSTALL_DIR)"
	ditto "$(APP)" "$(INSTALL_DIR)/$(APP_NAME).app"
	open "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"

uninstall: ## Quit and move the installed app to the Trash (settings are kept)
	-@pkill -x $(APP_NAME) || true
	@if [ -d "$(INSTALL_DIR)/$(APP_NAME).app" ]; then \
		mv "$(INSTALL_DIR)/$(APP_NAME).app" "$(HOME)/.Trash/$(APP_NAME)-$(STAMP).app" && \
		echo "Moved $(INSTALL_DIR)/$(APP_NAME).app to the Trash"; \
	else echo "Nothing installed in $(INSTALL_DIR)"; fi
	@echo "Settings stay in ~/Library/Application Support/MeetingGuru"

zip: app ## Package a release zip and its SHA-256 checksum
	cd dist && ditto -c -k --keepParent $(APP_NAME).app $(APP_NAME)-$(VERSION).zip
	cd dist && shasum -a 256 $(APP_NAME)-$(VERSION).zip | tee $(APP_NAME)-$(VERSION).zip.sha256

clean: ## Remove build output
	rm -rf .build dist
