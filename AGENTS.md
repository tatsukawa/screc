# AGENTS.md

Notes for coding agents, and for people, working on screc. Read [docs/how-it-works.md](docs/how-it-works.md) for the
design; this file covers how to work on it.

## Commands

```sh
make                                   # release build; ./screc links to .build/release/screc
make test                              # tests that need no screen; run after every change
make app                               # build/screc.app (universal, ad hoc signed)
make dmg                               # build/screc.dmg, the drag-to-Applications installer
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
Sources/ScrecKit/     options, what to record, record(), the GUI (GUI/: Session, Picker, overlays, toolbar, stop panel)
Sources/ScrecMedia/   MovieWriter and mixAudioTracks: the only AVAssetWriter/Reader code
Tests/ScrecKitTests/  unit tests, headless UI tests, OnScreenTests (opt-in)
Packaging/            Info.plist, entitlements, AppIcon.icon, build-app.sh (the app and the DMG)
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
  `OptionsTests`. If the option has a counterpart in the Options menu, `Preferences.overridden(by:)` must take it over
  when it was given (`Options.given`), and the menu must not store it.
- Every GUI setting lives in the toolbar's Options menu, as in ⌘⇧5. Do not bring back a separate settings window
  (see below). Settings are read with `Preferences.load()` and written by `Picker.choose(_:)` only, one setting at a time.
  Tests use a throwaway defaults domain (`TemporaryDefaults`), never the user's.
- `Packaging/AppIcon.icon` is an Icon Composer document (`icon.json` plus SVG layers). Let macOS draw the glass:
  keep the layers flat shapes. Preview it without opening anything with
  `"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" Packaging/AppIcon.icon
  --export-image --output-file icon.png --platform macOS --rendition Default --width 512 --height 512 --scale 1`
  (also `--rendition Dark`).
- Do not open the app (`open build/screc.app`) unasked: it covers the user's screen and may trigger permission
  prompts. Check the bundle with `codesign`, `plutil` and `lipo` instead, and ask the user to try it.
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
- **Window-capture functions are unavailable** in the current SDK. The snapshot test looks up
  `CGWindowListCreateImageFromArray` at run time and captures only its own windows, which needs no permission and
  cannot pick up anything else on the screen. Do not use that in the product.
- **Never write to the destination path directly.** `OutputFile` stages the recording and publishes it with a no-clobber
  rename. `fileExists` follows symbolic links, so existence checks use `lstat`. Delete only what screc created.
- **Writer failures must stop the recording.** `MovieWriter.onFailure` reports them at once; before, a full disk went
  unnoticed until the user stopped.
- **The GUI names displays and windows by ID**, never by index or title, and `--window` refuses names that match
  several windows. Recording the wrong target can expose private content.
- **Validate numbers strictly.** `compactMap` once turned `--region 10,typo,20,300,200` into a different region, and
  `--duration inf` crashed the timer after recording had started.
- **Text from other programs** (window titles, device names) goes through `printable()` before it is printed.
- **An app opened from Finder has no terminal.** Errors must also reach the user as a dialog (`fail()` does this in the
  GUI), or the app just disappears.
- **A separate Settings window made screc look stuck.** It could end up behind other apps, leaving an app without a
  Dock icon that seemed to run but could not be opened. All settings went into the Options menu instead.
- **Users could not tell whether the app was running.** It was an agent app (`LSUIElement`) with no Dock icon or
  menu bar. Opened as an app, screc is now a regular app while it runs; quitting while recording saves first
  (`ScrecAppDelegate.applicationShouldTerminate`).
- **Opening the app again did nothing.** `applicationShouldHandleReopen` now brings back the picker, the stop panel or
  the open dialog.
- **Dialogs hid while screc was inactive.** Panels hide on deactivation by default; the error dialog and the folder
  chooser set `hidesOnDeactivate = false`. An app opened from Finder is not always allowed to become active.
- **Snapshot tests failed on every first run.** Only one of them created `SCREC_SNAPSHOT_DIR`, and tests run in name
  order, so another wrote first into a folder that did not exist yet. Each snapshot test now calls
  `snapshotDirectory()`. (On-screen tests also wait for the window server with `waitUntilOnScreen` rather than a fixed
  delay; that was a first, wrong guess at this failure, but it does no harm.)
- **A picker that was gone was still read.** Overlay views and toolbar callbacks held the picker `unowned`; once a
  new picker was made for every recording, a window could draw after its picker was freed, and crashed. They hold it
  `weak` now, and do nothing once it is gone.
- **Found in a review by Codex** (each has a test): `--window 4294967296` overflowed the window ID and fell back to a
  title search; a second Ctrl+C racing the final rename could report "discarded" for a saved file (`StopSignals.finish`);
  ⌘Q while capture was starting quit without saving (`requestStop(duringStartup:)`); stopping early left the
  `--duration` timer alive for up to a week; choosing one Options entry rewrote every stored setting
  (`Preferences.save(_:to:)` writes one key); the size shown per hour was called an upper bound, but a target bitrate
  is not a cap, so it is an estimate.
- **The app vanished after one recording.** A regular app stays open: `GUISession` goes back to idle after a
  recording or a cancelled picker, and quits only when screc was run from a terminal.

## Commits

English, an imperative subject line of at most 72 characters, and a body that says why when it is not obvious.
Recordings (`*.mp4`) are ignored by git; never add one.
