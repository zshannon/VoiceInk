# Define a directory for dependencies in the project
DEPS_DIR := .deps
WHISPER_CPP_DIR := $(DEPS_DIR)/whisper.cpp
FRAMEWORK_PATH := $(WHISPER_CPP_DIR)/build-apple/whisper.xcframework

# Distribution settings
BUILD_DIR := build
ARCHIVE_PATH := $(BUILD_DIR)/VoiceInk.xcarchive
EXPORT_PATH := $(BUILD_DIR)/export
APP_PATH := $(EXPORT_PATH)/VoiceInk.app
TEAM_ID := NRD52JHX45
KEYCHAIN_PROFILE := AC_PASSWORD

.PHONY: all clean whisper setup build check healthcheck help dev run archive export notarize dmg release sparkle-sign upload-r2 upload-appcast publish bump

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
	@pkill -x VoiceInk 2>/dev/null || true
	@APP_PATH=$$(xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -showBuildSettings 2>/dev/null | grep "BUILT_PRODUCTS_DIR" | head -1 | awk '{print $$3}')/VoiceInk.app && \
	if [ -d "$$APP_PATH" ]; then \
		echo "Launching $$APP_PATH"; \
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
		-allowProvisioningUpdates \
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

# Sparkle signing and R2 upload
sparkle-sign:
	@echo "Signing DMG with Sparkle..."
	$(eval VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$(APP_PATH)/Contents/Info.plist"))
	$(eval DMG_FILE := $(BUILD_DIR)/VoiceInk-$(VERSION).dmg)
	@op run --env-file .env.op -- sh -c 'echo "$$SPARKLE_PRIVATE_KEY" | ./bin/sign_update -f - -p "$(DMG_FILE)"' > $(BUILD_DIR)/sparkle-signature.txt
	@echo "Sparkle signature saved to $(BUILD_DIR)/sparkle-signature.txt"

upload-r2: sparkle-sign
	@echo "Uploading DMG to R2..."
	$(eval VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$(APP_PATH)/Contents/Info.plist"))
	$(eval DMG_FILE := $(BUILD_DIR)/VoiceInk-$(VERSION).dmg)
	op run --env-file .env.op -- bash -c 'curl -s -X PUT "https://$$CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com/$$R2_BUCKET_NAME/VoiceInk-$(VERSION).dmg" \
		--aws-sigv4 "aws:amz:auto:s3" -u "$$AWS_ACCESS_KEY_ID:$$AWS_SECRET_ACCESS_KEY" \
		-H "Content-Type: application/octet-stream" --data-binary @"$(DMG_FILE)"'
	@echo "DMG uploaded to R2"

upload-appcast: upload-r2
	@echo "Generating and uploading appcast.xml..."
	$(eval VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$(APP_PATH)/Contents/Info.plist"))
	$(eval BUILD_NUM := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$(APP_PATH)/Contents/Info.plist"))
	$(eval DMG_FILE := $(BUILD_DIR)/VoiceInk-$(VERSION).dmg)
	$(eval DMG_SIZE := $(shell stat -f%z "$(DMG_FILE)"))
	$(eval SIGNATURE := $(shell cat $(BUILD_DIR)/sparkle-signature.txt))
	$(eval PUB_DATE := $(shell date -R))
	@op run --env-file .env.op -- sh -c 'printf "<?xml version=\"1.0\" standalone=\"yes\"?>\n<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\" version=\"2.0\">\n    <channel>\n        <title>VoiceInk</title>\n        <item>\n            <title>$(VERSION)</title>\n            <pubDate>$(PUB_DATE)</pubDate>\n            <sparkle:version>$(BUILD_NUM)</sparkle:version>\n            <sparkle:shortVersionString>$(VERSION)</sparkle:shortVersionString>\n            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>\n            <enclosure url=\"%sVoiceInk-$(VERSION).dmg\" length=\"$(DMG_SIZE)\" type=\"application/octet-stream\" sparkle:edSignature=\"$(SIGNATURE)\"/>\n        </item>\n    </channel>\n</rss>\n" "$$R2_PUBLIC_URL/" > $(BUILD_DIR)/appcast.xml'
	op run --env-file .env.op -- bash -c 'curl -s -X PUT "https://$$CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com/$$R2_BUCKET_NAME/appcast.xml" \
		--aws-sigv4 "aws:amz:auto:s3" -u "$$AWS_ACCESS_KEY_ID:$$AWS_SECRET_ACCESS_KEY" \
		-H "Content-Type: application/xml" --data-binary @"$(BUILD_DIR)/appcast.xml"'
	@echo "Appcast uploaded to R2"

publish: upload-appcast
	@echo "Release published to R2!"
	@op run --env-file .env.op -- sh -c 'echo "DMG: $$R2_PUBLIC_URL/VoiceInk-$(VERSION).dmg"'
	@op run --env-file .env.op -- sh -c 'echo "Appcast: $$R2_PUBLIC_URL/appcast.xml"'

# Version management
bump:
	$(eval CURRENT := $(shell grep -m1 'MARKETING_VERSION = ' VoiceInk.xcodeproj/project.pbxproj | sed 's/.*= \(.*\);/\1/'))
	$(eval NEW := $(shell echo "$(CURRENT) + 0.01" | bc))
	$(eval NEW_BUILD := $(shell echo "$(NEW) * 100" | bc | cut -d. -f1))
	@sed -i '' 's/MARKETING_VERSION = $(CURRENT);/MARKETING_VERSION = $(NEW);/g' VoiceInk.xcodeproj/project.pbxproj
	@sed -i '' 's/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $(NEW_BUILD);/g' VoiceInk.xcodeproj/project.pbxproj
	@echo "Bumped version: $(CURRENT) -> $(NEW) (build $(NEW_BUILD))"

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
	@echo "Publishing (requires .env.op with 1Password refs):"
	@echo "  bump               Bump version number (1.70 -> 1.71)"
	@echo "  sparkle-sign       Sign DMG with Sparkle EdDSA key"
	@echo "  upload-r2          Upload DMG to Cloudflare R2"
	@echo "  upload-appcast     Generate and upload appcast.xml to R2"
	@echo "  publish            Full publish (dmg->sign->upload->appcast)"
	@echo ""
	@echo "Cleanup:"
	@echo "  clean              Remove dependencies"
	@echo "  clean-dist         Remove distribution build artifacts"
	@echo "  help               Show this help message"