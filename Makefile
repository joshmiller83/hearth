# Everyday commands. `make` lists them.
SHELL := /bin/bash
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

# Your iPhone, for install-phone. Put the ids in iOS/Config/device.env (git-ignored):
#   DEVICE_ID=<xcodebuild destination id>   DEVICECTL_ID=<devicectl device id>
-include iOS/Config/device.env
SIMULATOR ?= iPhone 17 Pro
DERIVED := build/DerivedData
# Everything swift format checks (never .build).
SWIFT_SOURCES = Packages/HearthKit/Sources Packages/HearthKit/Tests Packages/HearthKit/Package.swift \
  Relay/Sources Relay/Tests $(wildcard iOS/App iOS/HearthCore/Sources iOS/HearthCore/Tests iOS/Widgets iOS/Share iOS/Tests iOS/UITests iOS/SnapshotTests)

.PHONY: help test test-kit test-relay test-core test-all project build snapshots lint format \
        install-phone relay-it eval status deploy

help:
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-14s %s\n", $$1, $$2}'

test: test-kit test-relay test-core ## What CI runs: HearthKit, the relay and HearthCore

test-kit: ## HearthKit's tests
	swift test --package-path Packages/HearthKit

test-relay: ## The relay's tests (fake gmailkit, in-memory database)
	swift test --package-path Relay

test-core: ## HearthCore's tests (macOS, no simulator)
	swift test --package-path iOS/HearthCore

project: ## Generate iOS/Hearth.xcodeproj from iOS/project.yml
	@test -f iOS/Config/Local.xcconfig || { echo "Copy iOS/Config/Local.xcconfig.example to iOS/Config/Local.xcconfig first."; exit 1; }
	cd iOS && xcodegen generate --quiet

build: project ## Build the app for the simulator, as CI does
	xcodebuild build -quiet -project iOS/Hearth.xcodeproj -scheme Hearth \
	  -destination 'generic/platform=iOS Simulator' -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO

test-all: test project ## Everything: the packages, then app, UI and snapshot tests on a simulator
	xcodebuild test -quiet -project iOS/Hearth.xcodeproj -scheme Hearth \
	  -destination 'platform=iOS Simulator,name=$(SIMULATOR)' -derivedDataPath $(DERIVED)

snapshots: project ## Snapshot tests only (set RECORD=1 to re-record)
	TEST_RUNNER_SNAPSHOT_TESTING_RECORD=$(if $(RECORD),all,missing) xcodebuild test -quiet -project iOS/Hearth.xcodeproj -scheme Hearth \
	  -destination 'platform=iOS Simulator,name=$(SIMULATOR)' -derivedDataPath $(DERIVED) -only-testing:HearthSnapshotTests

lint: ## swift format lint, as CI runs it
	swift format lint --strict --recursive $(SWIFT_SOURCES)

format: ## swift format, in place
	swift format format --in-place --recursive $(SWIFT_SOURCES)

install-phone: project ## Build Debug for your iPhone and install it over USB or Wi-Fi
	@test -n "$(DEVICE_ID)" -a -n "$(DEVICECTL_ID)" || { echo "Set DEVICE_ID and DEVICECTL_ID in iOS/Config/device.env"; exit 1; }
	xcodebuild build -quiet -project iOS/Hearth.xcodeproj -scheme Hearth -configuration Debug \
	  -destination 'id=$(DEVICE_ID)' -derivedDataPath $(DERIVED) -allowProvisioningUpdates
	xcrun devicectl device install app --device $(DEVICECTL_ID) $(DERIVED)/Build/Products/Debug-iphoneos/Hearth.app

relay-it: ## Read-only run of the calendar job against the real gmailkit (iMac only)
	cd Relay && swift build --product Run && HEARTH_DB=$$(mktemp -d)/it.sqlite HEARTH_HOUSEHOLD=$$HOME/HearthRelay/household.json \
	  .build/debug/Run run-job calendar

eval: ## Live Claude prompt checks on synthetic flyers and notes (costs cents; needs ANTHROPIC_API_KEY)
	swift run --package-path Packages/HearthKit hearth-eval

status: ## The deployed relay: daemons, health, deployed commit vs main
	deploy/status.sh

deploy: ## Test, build and restart the relay (no sudo)
	deploy/update.sh
