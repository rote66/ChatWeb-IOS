SHELL := /bin/bash
SIMULATOR_NAME ?= iPhone 17 Pro

.PHONY: debug release test static-check ipa

debug:
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DualAI.xcodeproj -scheme DualAI -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedDataDebug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

release:
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DualAI.xcodeproj -scheme DualAI -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedDataRelease CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 build

test:
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DualAI.xcodeproj -scheme DualAI -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=$(SIMULATOR_NAME)' -derivedDataPath build/DerivedDataTests CODE_SIGNING_ALLOWED=NO test

static-check:
	./scripts/static_check.sh

ipa:
	./scripts/build_ipa.sh
