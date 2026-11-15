.PHONY: all build bundle clean run test icon release release-bundle signed-release-bundle local-dmg dmg checksum notarize verify-release install

APP_NAME := LLMenuBar
APP_IDENTIFIER := com.jiiim.llmenubar
APP_ARCH := arm64
MINIMUM_SYSTEM_VERSION := 26.0
APP := .build/debug/LLMenuBar.app
RELEASE_APP := .build/release/LLMenuBar.app
VERSION ?= $(shell plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
BUILD_NUMBER ?= $(shell plutil -extract CFBundleVersion raw Resources/Info.plist)
DIST_DIR ?= dist
DMG := $(DIST_DIR)/LLMenuBar-v$(VERSION)-$(APP_ARCH).dmg
DMG_SHA256 := $(DMG).sha256
SIGN_IDENTITY ?=
NOTARY_PROFILE ?=

all: bundle

build:
	swift build --arch $(APP_ARCH)

test:
	swift test

# ProcessManager drives a live child process across three queues, so the
# sanitizer is the only thing that actually proves the main-queue confinement
# the type asserts. Slow; not part of `test`.
test-tsan:
	swift test --sanitize=thread

bundle: build
	./scripts/create-app-bundle.sh debug "$(APP)" "$(VERSION)" "$(BUILD_NUMBER)" "$(APP_IDENTIFIER)" "$(MINIMUM_SYSTEM_VERSION)" ""

run: bundle
	open -g "$(APP)"

# Regenerate Resources/AppIcon.icns from the generator script. The script is
# compiled with LogoMark.swift and LogoArtwork.swift, so it is copied to
# main.swift for swiftc.
icon:
	mkdir -p .build/icon
	cp scripts/generate-icon.swift .build/icon/main.swift
	swiftc -o .build/icon/generate-icon .build/icon/main.swift Sources/llmenubar/LogoMark.swift Sources/llmenubar/LogoArtwork.swift
	.build/icon/generate-icon

release:
	swift build -c release --arch $(APP_ARCH)

release-bundle: release
	./scripts/create-app-bundle.sh release "$(RELEASE_APP)" "$(VERSION)" "$(BUILD_NUMBER)" "$(APP_IDENTIFIER)" "$(MINIMUM_SYSTEM_VERSION)" ""

# Re-sign the release app for distribution with the hardened runtime and a
# trusted timestamp. SIGN_IDENTITY must be a Developer ID Application identity.
signed-release-bundle: release
	@test -n "$(SIGN_IDENTITY)" || (echo 'SIGN_IDENTITY is required (for example: Developer ID Application: Example Corp (TEAMID))' >&2; exit 1)
	./scripts/create-app-bundle.sh release "$(RELEASE_APP)" "$(VERSION)" "$(BUILD_NUMBER)" "$(APP_IDENTIFIER)" "$(MINIMUM_SYSTEM_VERSION)" "$(SIGN_IDENTITY)"

# Produces the same drag-to-Applications layout without requiring a certificate.
# The app uses an ad-hoc signature and is intended only for packaging checks.
local-dmg: release-bundle
	rm -f "$(DMG_SHA256)"
	./scripts/create-dmg.sh "$(RELEASE_APP)" "$(DMG)" "$(APP_NAME)"
	$(MAKE) checksum VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" DIST_DIR="$(DIST_DIR)"

# Not a release path. It rebuilds the app, which discards the notarization
# ticket stapled to the app, and a ticket on the image alone does not survive
# the app being copied out of it. The release steps are in
# release/release-process.md; `make local-dmg` checks packaging.
dmg:
	@echo 'make dmg is not used for a release: it rebuilds the app and drops its stapled ticket. Follow release/release-process.md; use make local-dmg for a packaging check.' >&2
	@exit 1

checksum:
	@test -f "$(DMG)" || (echo 'DMG not found: $(DMG)' >&2; exit 1)
	@hash=$$(shasum -a 256 "$(DMG)" | awk '{print $$1}'); printf '%s  %s\n' "$$hash" "$(notdir $(DMG))" > "$(DMG_SHA256)"

# Not a release path: it notarizes only the image, after `dmg` rebuilt the app
# without its ticket. See release/release-process.md for the order that works
# (app, then image).
notarize:
	@echo 'make notarize is not used for a release: it notarizes the image only. Follow release/release-process.md.' >&2
	@exit 1

# Checks the shipped artifact only. The app is verified inside the mounted
# image, so this target needs no .build tree and can verify a downloaded
# release as well as a local one.
verify-release:
	hdiutil verify "$(DMG)"
	codesign --verify --strict --verbose=2 "$(DMG)"
	spctl --assess --type open --context context:primary-signature --verbose=4 "$(DMG)"
	xcrun stapler validate "$(DMG)"
	./scripts/verify-dmg-app.sh "$(DMG)" "$(APP_NAME).app" "$(APP_IDENTIFIER)" "$(VERSION)" "$(BUILD_NUMBER)"
	@test -f "$(DMG_SHA256)" || (echo 'checksum not found: $(DMG_SHA256)' >&2; exit 1)
	@expected=$$(awk '{print $$1}' "$(DMG_SHA256)"); actual=$$(shasum -a 256 "$(DMG)" | awk '{print $$1}'); test "$$expected" = "$$actual"

# Build a release bundle and install it to /Applications, quitting a
# running instance first (stable install path keeps launch-services
# state consistent, matches athenaeum's build-app.sh).
install: release-bundle
	osascript -e 'tell application id "$(APP_IDENTIFIER)" to quit' 2>/dev/null || true
	@# Quitting stops the engine first, which can take as long as its
	@# force-kill grace, or it can wait on a confirmation. Wait until the
	@# app has exited; never replace an app that is still running.
	@if pgrep -f "/Applications/LLMenuBar.app/Contents/MacOS/llmenubar" >/dev/null; then \
		echo 'Waiting for LLMenuBar to quit (Ctrl-C to cancel)...' >&2; \
		while pgrep -f "/Applications/LLMenuBar.app/Contents/MacOS/llmenubar" >/dev/null; do sleep 1; done; \
	fi
	rm -rf "/Applications/LLMenuBar.app"
	cp -R "$(RELEASE_APP)" /Applications/
	open -g "/Applications/LLMenuBar.app"

clean:
	rm -rf .build
