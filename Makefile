.PHONY: build test app dev test-app run run-test install icon fmt clean

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

icon:
	swift scripts/make-icon.swift

fmt:
	npx -y oxfmt .

clean:
	rm -rf build .build
