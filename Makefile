SHELL := /bin/bash
SIMULATOR_NAME ?= iPhone 17 Pro

.PHONY: debug release test static-check ipa gecko-build gecko-export gecko-core

debug:
	bash scripts/prepare_gecko_prebuilt.sh
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ChatWeb.xcodeproj -scheme ChatWeb -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedDataDebug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

release:
	bash scripts/prepare_gecko_prebuilt.sh
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ChatWeb.xcodeproj -scheme ChatWeb -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedDataRelease CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 build

test:
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ChatWeb.xcodeproj -scheme ChatWeb -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=$(SIMULATOR_NAME)' -derivedDataPath build/DerivedDataTests CODE_SIGNING_ALLOWED=NO test

static-check:
	./scripts/static_check.sh

ipa:
	bash scripts/build_ipa.sh

gecko-build:
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash GeckoPort/build_gecko.sh

gecko-export:
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/export_gecko_prebuilt.sh

gecko-core: gecko-build gecko-export
