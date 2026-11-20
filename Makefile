.PHONY: build test clean app dmg

# Release build, with a `screc` link in this directory so that ./screc works.
build:
	swift build -c release
	ln -sf .build/release/screc screc

test:
	swift test

# build/screc.app, a regular macOS app (see Packaging/build-app.sh for signing and the bundle identifier).
app:
	Packaging/build-app.sh

# build/screc.dmg, the installer: open it and drag screc into Applications.
dmg:
	Packaging/build-app.sh dmg

clean:
	swift package clean
	rm -rf screc build
