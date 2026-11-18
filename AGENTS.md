# AGENTS.md

Notes for coding agents, and for people, working on screc. Read [docs/how-it-works.md](docs/how-it-works.md) for the
design; this file covers how to work on it.

## Commands

```sh
make                                   # release build; ./screc links to .build/release/screc
make test                              # tests that need no screen; run after every change
SCREC_UI_TESTS=1 swift test            # also the tests that put windows on the screen
SCREC_UI_TESTS=1 SCREC_SNAPSHOT_DIR=/tmp/screc-snapshots swift test   # and write pictures of the UI
./screc --help
```

## What can and cannot be checked

- **Recording itself** needs the screen recording permission for the process that runs screc. Agent sandboxes and CI
  normally lack it, and screc then exits with "screen recording is not permitted". Do not report a change to
  recording as working until a person has recorded with it. When they share a file, inspect it with `ffprobe` and
  `ffmpeg` (tracks, frame count, audio level) rather than relying on their impression alone. Do not look at the
  pictures in a user's recording unless they ask; it is their screen.
- **Picker logic** (selection, moving and resizing regions, which options are produced) is in `PickerModel` and the
  headless tests. Extend those tests when you change it.
- **Window-server behaviour and appearance** can only be checked with `SCREC_UI_TESTS=1`. Those tests flash windows on
  the user's screen for a few seconds, so say so before running them. After a visual change, look at the snapshots:
  Liquid Glass only renders in on-screen windows, and an off-screen `cacheDisplay` render shows a flat grey bar
  instead.

## Layout

```
Sources/screc/        main.swift: one line
Sources/ScrecKit/     options, what to record, record(), the GUI (GUI/)
Sources/ScrecMedia/   MovieWriter and mixAudioTracks: the only AVAssetWriter/Reader code
Tests/ScrecKitTests/  unit tests, headless UI tests, OnScreenTests (opt-in)
docs/                 how it works, troubleshooting
```

The GUI never records. It builds an `Options` value, exactly as the command line does, and calls `record(_:control:)`.
Keep it that way, so that every recording feature works from both.

## Conventions

- **English** for everything in the repository: code comments, documentation, commit messages, and all text the user
  sees (GUI labels, `--help`, messages).
- Comments say why, not what. Doc comments (`///`) on types and on functions whose purpose is not obvious from the name.
- No third-party dependencies, and nothing installed outside the repository. That is the point of the tool.
- Code that uses AVAssetWriter or AVAssetReader goes in `ScrecMedia`. Its deprecation warnings are silenced there and
  only there (see `Package.swift`).
- Geometry is in points with the origin at the top left, as in ScreenCaptureKit. AppKit's bottom-left window frames
  appear only where windows are placed (`PickDisplay.screenFrame`).
- Picker behaviour belongs in `PickerModel`, with tests. Views translate events into model calls and draw.
- When you add or change an option, update `usage` in `Options.swift`, the options table in `README.md`, and
  `OptionsTests`.
- Errors for the user go through `fail()`, start in lower case, and point to `--list` when that helps.
- Swift 6 toolchain, Swift 5 language mode (see `Package.swift`). The build should stay free of warnings.

## Things that broke before

Each of these was a real bug or trap. Keep the fix, and keep the test where there is one.

- **Clicks fell through the selection.** Fully transparent pixels of a window pass clicks to the window below unless
  `ignoresMouseEvents = false` is set explicitly. Without it, regions could not be moved.
  `OnScreenTests.testClicksInsideTheTransparentSelectionReachTheOverlay` covers it.
- **The stop panel has to be on screen before `record()` starts.** It is excluded from the recording by window ID,
  and ScreenCaptureKit is asked only for on-screen windows. `GUIApp.recordAndReveal` shows it first.
- **Users could not find how to stop.** A menu bar icon alone was missed, and the program vanished without a word
  after it was clicked. Hence the labelled panel and the "Saved" state before exiting.
- **Standard buttons turn grey in inactive windows** and look disabled. The overlay is rarely the active window, so
  the Record and Stop buttons are drawn by hand (`makeCapsuleButton`).
- **The Options menu opened behind the overlay** at screen-saver level. The overlay sits just below pop-up menus.
- **Enter and Esc only worked on one display.** They are caught by an app-wide local event monitor in `Picker.show()`.
- **A Bluetooth headset's microphone degrades what the user hears** (call mode, 16 kHz). `chooseMicrophone` avoids it
  unless asked for by name.
- **NSWorkspace printed pasteboard warnings** when revealing the file in Finder; `open -R` does not.
- **`CGWindowListCreateImage` is unavailable** in the current SDK. The snapshot test calls it by symbol name to capture
  its own windows, which needs no permission. Do not use that in the product.

## Commits

English, an imperative subject line of at most 72 characters, and a body that says why when it is not obvious.
Recordings (`*.mp4`) are ignored by git; never add one.
