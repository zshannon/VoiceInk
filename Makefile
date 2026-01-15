# Define a directory for dependencies in the user's home folder
DEPS_DIR := $(HOME)/VoiceInk-Dependencies
WHISPER_CPP_DIR := $(DEPS_DIR)/whisper.cpp
FRAMEWORK_PATH := $(WHISPER_CPP_DIR)/build-apple/whisper.xcframework

# Distribution settings
BUILD_DIR := build
ARCHIVE_PATH := $(BUILD_DIR)/VoiceInk.xcarchive
EXPORT_PATH := $(BUILD_DIR)/export
APP_PATH := $(EXPORT_PATH)/VoiceInk.app
TEAM_ID := NRD52JHX45
KEYCHAIN_PROFILE := AC_PASSWORD

.PHONY: all clean whisper setup build check healthcheck help dev run archive export notarize dmg release

# Default target
all: check build

# Development workflow
dev: build run

# Prerequisites
check:
	@echo "Checking prerequisites..."
	@command -v git >/dev/null 2>&1 || { echo "git is not installed"; exit 1; }
	@command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild is not installed (need Xcode)"; exit 1; }
	@command -v swift >/dev/null 2>&1 || { echo "swift is not installed"; exit 1; }
	@echo "Prerequisites OK"

healthcheck: check

# Build process
whisper:
	@mkdir -p $(DEPS_DIR)
	@if [ ! -d "$(FRAMEWORK_PATH)" ]; then \
		echo "Building whisper.xcframework in $(DEPS_DIR)..."; \
		if [ ! -d "$(WHISPER_CPP_DIR)" ]; then \
			git clone https://github.com/ggerganov/whisper.cpp.git $(WHISPER_CPP_DIR); \
		else \
			(cd $(WHISPER_CPP_DIR) && git pull); \
		fi; \
		cd $(WHISPER_CPP_DIR) && ./build-xcframework.sh; \
	else \
		echo "whisper.xcframework already built in $(DEPS_DIR), skipping build"; \
	fi

setup: whisper
	@echo "Whisper framework is ready at $(FRAMEWORK_PATH)"
	@echo "Please ensure your Xcode project references the framework from this new location."

build: setup
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug CODE_SIGN_IDENTITY="" build

# Run application
run:
	@echo "Looking for VoiceInk.app..."
	@APP_PATH=$$(find "$$HOME/Library/Developer/Xcode/DerivedData" -name "VoiceInk.app" -type d | head -1) && \
	if [ -n "$$APP_PATH" ]; then \
		echo "Found app at: $$APP_PATH"; \
		open "$$APP_PATH"; \
	else \
		echo "VoiceInk.app not found. Please run 'make build' first."; \
		exit 1; \
	fi

# Cleanup
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(DEPS_DIR)
	@echo "Clean complete"

clean-dist:
	@echo "Cleaning distribution build..."
	@rm -rf $(BUILD_DIR)
	@echo "Clean complete"

# Distribution targets
archive: setup
	@echo "Creating archive..."
	@mkdir -p $(BUILD_DIR)
	xcodebuild -project VoiceInk.xcodeproj \
		-scheme VoiceInk \
		-configuration Release \
		-archivePath $(ARCHIVE_PATH) \
		archive

export: archive
	@echo "Exporting archive..."
	@mkdir -p $(EXPORT_PATH)
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $(BUILD_DIR)/ExportOptions.plist
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $(BUILD_DIR)/ExportOptions.plist
	@echo '<plist version="1.0"><dict>' >> $(BUILD_DIR)/ExportOptions.plist
	@echo '<key>method</key><string>developer-id</string>' >> $(BUILD_DIR)/ExportOptions.plist
	@echo '<key>teamID</key><string>$(TEAM_ID)</string>' >> $(BUILD_DIR)/ExportOptions.plist
	@echo '<key>signingStyle</key><string>manual</string>' >> $(BUILD_DIR)/ExportOptions.plist
	@echo '<key>signingCertificate</key><string>Developer ID Application</string>' >> $(BUILD_DIR)/ExportOptions.plist
	@echo '<key>provisioningProfiles</key><dict>' >> $(BUILD_DIR)/ExportOptions.plist
	@echo '<key>me.zcs.VoiceInk</key><string>VoiceInk Developer ID</string>' >> $(BUILD_DIR)/ExportOptions.plist
	@echo '</dict></dict></plist>' >> $(BUILD_DIR)/ExportOptions.plist
	xcodebuild -exportArchive \
		-archivePath $(ARCHIVE_PATH) \
		-exportPath $(EXPORT_PATH) \
		-exportOptionsPlist $(BUILD_DIR)/ExportOptions.plist

notarize: export
	@echo "Zipping app for notarization..."
	cd $(EXPORT_PATH) && ditto -c -k --keepParent VoiceInk.app VoiceInk.zip
	@echo "Submitting for notarization..."
	xcrun notarytool submit $(EXPORT_PATH)/VoiceInk.zip \
		--keychain-profile "$(KEYCHAIN_PROFILE)" \
		--wait
	@echo "Stapling notarization ticket..."
	xcrun stapler staple $(APP_PATH)
	@echo "Verifying notarization..."
	spctl -a -vv $(APP_PATH)
	@rm -f $(EXPORT_PATH)/VoiceInk.zip

dmg: notarize
	@echo "Creating DMG..."
	$(eval VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$(APP_PATH)/Contents/Info.plist"))
	@rm -f $(BUILD_DIR)/VoiceInk-$(VERSION).dmg
	@rm -rf $(BUILD_DIR)/dmg-staging
	@mkdir -p $(BUILD_DIR)/dmg-staging
	@cp -R $(APP_PATH) $(BUILD_DIR)/dmg-staging/
	@ln -s /Applications $(BUILD_DIR)/dmg-staging/Applications
	hdiutil create -volname "VoiceInk" \
		-srcfolder $(BUILD_DIR)/dmg-staging \
		-ov -format UDZO \
		$(BUILD_DIR)/VoiceInk-$(VERSION).dmg
	@rm -rf $(BUILD_DIR)/dmg-staging
	@echo "Signing DMG..."
	codesign --force --sign "555066E4A3E7123BE9E073B0A7E3AE1F355669A1" \
		$(BUILD_DIR)/VoiceInk-$(VERSION).dmg
	@echo "DMG created: $(BUILD_DIR)/VoiceInk-$(VERSION).dmg"

release: dmg
	@echo "Release build complete!"
	@ls -la $(BUILD_DIR)/*.dmg

# Help
help:
	@echo "Available targets:"
	@echo ""
	@echo "Development:"
	@echo "  check/healthcheck  Check if required CLI tools are installed"
	@echo "  whisper            Clone and build whisper.cpp XCFramework"
	@echo "  setup              Copy whisper XCFramework to VoiceInk project"
	@echo "  build              Build the VoiceInk Xcode project (Debug)"
	@echo "  run                Launch the built VoiceInk app"
	@echo "  dev                Build and run the app (for development)"
	@echo "  all                Run full build process (default)"
	@echo ""
	@echo "Distribution:"
	@echo "  archive            Build Release archive"
	@echo "  export             Export signed app from archive"
	@echo "  notarize           Submit to Apple and staple ticket"
	@echo "  dmg                Create signed DMG"
	@echo "  release            Full distribution build (archive->export->notarize->dmg)"
	@echo ""
	@echo "Cleanup:"
	@echo "  clean              Remove dependencies"
	@echo "  clean-dist         Remove distribution build artifacts"
	@echo "  help               Show this help message"