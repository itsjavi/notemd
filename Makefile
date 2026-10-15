.PHONY: build test app dev test-app run run-test install release appcast bump build-notarized install-notarized icon fmt clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh release

dev:
	scripts/build-app.sh dev

test-app:
	scripts/build-app.sh test

run: dev
	open "build/NoteMD Dev.app"

# Agents: launch the background Test build without stealing focus.
run-test: test-app
	open -g "build/NoteMD Test.app"

install: app
	-osascript -e 'tell application id "com.itsjavi.notemd" to quit' 2>/dev/null
	rm -rf /Applications/NoteMD.app
	cp -R build/NoteMD.app /Applications/NoteMD.app

# Apple silicon app, zip and DMG in build/release; signs and notarizes when DEVELOPER_ID and
# NOTARY_PROFILE are set, otherwise builds ad-hoc and lists what's missing (see scripts/release.sh).
release:
	scripts/release.sh

# Signs build/release's zip (EdDSA key "notemd" from the Keychain) and updates build/appcast/appcast.xml.
appcast:
	scripts/appcast.sh

# Bumps VERSION, commits and tags it: make bump V=patch|minor|major|X.Y.Z [PUSH=1] (docs/releasing.md)
bump:
	scripts/bump-version.sh $(V) $(if $(PUSH),--push)

# scripts/release.sh with this Mac's credentials: DEVELOPER_ID defaults to the Keychain's Developer ID
# Application identity and NOTARY_PROFILE to "lamina" (the notarytool profile Lamina and QuickEdit use: same
# Apple ID and team; any profile for the team works). Without an identity it stops instead of building ad-hoc.
build-notarized:
	@identity="$${DEVELOPER_ID:-$$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"; \
	if [ -z "$$identity" ]; then echo "error: no Developer ID Application identity in the Keychain" >&2; exit 1; fi; \
	DEVELOPER_ID="$$identity" NOTARY_PROFILE="$${NOTARY_PROFILE:-lamina}" scripts/release.sh

# Like install, with the notarized build. The Share menu lists NoteMD once it's in /Applications.
install-notarized: build-notarized
	-osascript -e 'tell application id "com.itsjavi.notemd" to quit' 2>/dev/null
	rm -rf /Applications/NoteMD.app
	cp -R build/release/NoteMD.app /Applications/NoteMD.app

icon:
	swift scripts/make-icon.swift

fmt:
	npx -y oxfmt .

clean:
	rm -rf build .build
