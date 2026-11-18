.PHONY: build test clean

# Release build, with a `screc` link in this directory so that ./screc works.
build:
	swift build -c release
	ln -sf .build/release/screc screc

test:
	swift test

clean:
	swift package clean
	rm -f screc
