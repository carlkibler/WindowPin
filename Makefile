# WindowPin — pin windows above other apps.
#
# Two ways to build:
#
#   make app / make install / make run
#       Self-contained local build: SwiftPM, ad-hoc signed, no Sparkle and no
#       update checks. Needs nothing beyond the Xcode command line tools.
#
#   gmake build / gmake release
#       The signed, notarised release pipeline, delegated to the shared
#       `release.mk` from PerpetualBeta/jorvik-release (checked out beside this
#       repo, or wherever JORVIK_RELEASE points). Embeds Sparkle.

BUNDLE_NAME      := WindowPin
BUNDLE_TYPE      := app
PRODUCT_NAME     := WindowPin.app
BUNDLE_ID        := cc.jorviksoftware.WindowPin
BUILD_SYSTEM     := spm
SPM_PRODUCT      := WindowPin

PACKAGE_TYPE     := zip
ALSO_SHIP_PKG    := true
EMBEDDED_FRAMEWORKS := Sparkle
ENTITLEMENTS     := WindowPin.entitlements

JORVIK_RELEASE   ?= ../jorvik-release

ifneq ($(wildcard $(JORVIK_RELEASE)/release.mk),)
include $(JORVIK_RELEASE)/release.mk
else
.DEFAULT_GOAL := app
build release:
	@echo "$@ needs the release pipeline: clone PerpetualBeta/jorvik-release to $(JORVIK_RELEASE)," >&2
	@echo "or set JORVIK_RELEASE. For a local build without it, use: make app" >&2
	@exit 1
clean:
	rm -rf .build/local
endif

# MARK: - Local build (no release pipeline, no Sparkle)

# Written as single shell commands so they behave the same whether or not
# release.mk (which turns on .ONESHELL and bash) is included.
LOCAL_APP        := .build/local/$(PRODUCT_NAME)
LOCAL_BUNDLE_ID  ?= $(BUNDLE_ID)
INSTALL_DIR      ?= $(HOME)/Applications
PLISTBUDDY       := /usr/libexec/PlistBuddy

.PHONY: app install run

app:
	swift build -c release --product $(SPM_PRODUCT) && \
	BIN="$$(swift build -c release --show-bin-path)/$(SPM_PRODUCT)" && \
	rm -rf "$(LOCAL_APP)" && \
	mkdir -p "$(LOCAL_APP)/Contents/MacOS" "$(LOCAL_APP)/Contents/Resources" && \
	cp "$$BIN" "$(LOCAL_APP)/Contents/MacOS/$(BUNDLE_NAME)" && \
	cp -R Resources/ "$(LOCAL_APP)/Contents/Resources/" && \
	cp Info.plist "$(LOCAL_APP)/Contents/Info.plist" && \
	for KEY in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUScheduledCheckInterval; do \
		$(PLISTBUDDY) -c "Delete :$$KEY" "$(LOCAL_APP)/Contents/Info.plist" 2>/dev/null || true; \
	done && \
	$(PLISTBUDDY) -c "Set :CFBundleIdentifier $(LOCAL_BUNDLE_ID)" "$(LOCAL_APP)/Contents/Info.plist" && \
	codesign --force --sign - --entitlements $(ENTITLEMENTS) "$(LOCAL_APP)" && \
	echo "Built $(LOCAL_APP)"

install: app
	mkdir -p "$(INSTALL_DIR)" && \
	rm -rf "$(INSTALL_DIR)/$(PRODUCT_NAME)" && \
	ditto "$(LOCAL_APP)" "$(INSTALL_DIR)/$(PRODUCT_NAME)" && \
	echo "Installed $(INSTALL_DIR)/$(PRODUCT_NAME)"

run: app
	open "$(LOCAL_APP)"
