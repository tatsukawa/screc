# screc

Record your Mac's screen **together with the sound it is playing**, without BlackHole or any other virtual audio
device, without a driver, and without anything running in the background.

Recording the screen with system audio has traditionally meant installing a virtual audio device and routing the Mac's
output through it. screc does not need that: it uses only Apple's ScreenCaptureKit, which can capture system audio
directly. screc is an ordinary app (and the same program works from a terminal); nothing else is installed, and
nothing is left behind when you delete it.

- Record a whole display, a single window, or a region you draw
- System audio, and optionally a microphone, in a single audio track
- An on-screen picker in the style of ⌘⇧5, or plain command-line options
- Options for where recordings go, their quality and format, and what happens after saving, remembered between runs
- An estimate of how large an hour of recording will be, and options to make it smaller
- `.mp4` files in H.264 or HEVC, at the display's full Retina resolution by default

## Requirements

- macOS 15 or later to run, on Apple silicon or Intel
- Xcode 26 or later to build (Swift 6 and the macOS 26 SDK)

screc has only been used on macOS 27 so far. It is written for macOS 15 and later, and the Liquid Glass look of the
picker falls back to a blurred background before macOS 26, but neither has been tried on an older system yet.

## Install the app

```sh
git clone <this repository>
cd screc
make dmg
open build/screc.dmg
```

Drag **screc** onto **Applications** in the window that opens. From then on, open screc like any other app: from
Launchpad, Spotlight or the Applications folder.

screc stays open between recordings, with its icon in the Dock. Start the next recording by clicking the Dock icon,
with **File → New Recording** (⌘N), or from the Dock icon's menu. While recording, that menu has **Stop Recording**,
and quitting (⌘Q) stops and saves the recording first. Run from a terminal, screc is a command instead: it quits
after one recording, or when the picker is cancelled.

`make app` builds only `build/screc.app`, without the disk image.

The app is signed ad hoc, which is enough on the Mac that built it. On another Mac, macOS refuses to open an app
downloaded from the internet unless it is signed with an Apple Developer ID and notarized. To distribute screc, build
it with your own identifier and Developer ID, then notarize the disk image:

```sh
BUNDLE_ID=com.example.screc SIGN_IDENTITY="Developer ID Application: …" make dmg
```

Notarization itself (`xcrun notarytool submit build/screc.dmg …`) needs your Apple developer account and is not part
of the build.

## Use it from a terminal

```sh
make            # builds .build/release/screc and links ./screc to it
./screc --help
```

The binary has no dependencies; copy it onto your `PATH` to run it from anywhere. The app contains the same program:
`/Applications/screc.app/Contents/MacOS/screc --help` works too.

## Permission

The first time you record, macOS asks for permission to record the screen. Allow it in
**System Settings → Privacy & Security → Screen & System Audio Recording**, then open screc again.

The permission belongs to whatever started screc: the screc app when you open the app, or your terminal app
(Terminal, iTerm2, …) when you run screc from it. If you rebuild the app, macOS may ask again, because an ad hoc
signature changes with every build.

## Recording with the picker

Open the screc app, or run `./screc` without options. The screen dims and a toolbar appears near the bottom of it:

| Control                     | Does                                                    |
| --------------------------- | ------------------------------------------------------- |
| ✕                           | Cancel (or press Esc)                                   |
| Display / Window / Region   | What to record                                          |
| Options                     | Every setting (see below)                               |
| Record                      | Start recording (or press Enter)                        |

- **Display**: click the display to record, or press Enter.
- **Window**: move the pointer over a window to highlight it, then click it.
- **Region**: drag out a rectangle. Drag inside it to move it, also onto another display, and drag its edges or
  corners to resize it. Then press Enter or click Record.

The line under the toolbar shows what will be recorded, at which resolution, and how much disk space one hour
is estimated to take. The toolbar can be moved by dragging its edge. The microphone and quality chosen under Options are
remembered for next time.

While recording, a panel at the top of the screen shows the elapsed time and a **Stop** button. The menu bar has the
same button. The panel is left out of the recording. When you stop, the panel says "Saved", and the file is shown in
Finder (see Options).

If the picker ever stops responding when started from a terminal, press Ctrl+C there.

## Options

As in ⌘⇧5, every setting is in the toolbar's **Options** menu; there is no separate settings window. A choice takes
effect at once and is remembered for the next time.

| Section      | Choices                                                                  | Default        |
| ------------ | ------------------------------------------------------------------------ | -------------- |
| Save to      | Movies, Desktop, Documents, or any folder with **Other Location…**       | Movies         |
| Microphone   | None, or one of the Mac's microphones                                    | None           |
| Quality      | High, Standard, Small (half resolution)                                  | Standard       |
| Format       | H.264 (plays everywhere), HEVC (smaller files)                           | H.264          |
| Frame Rate   | 60 or 30 fps                                                             | 60 fps         |
| Options      | Show Mouse Pointer                                                       | On             |
| After Saving | Show in Finder, Open, Do Nothing                                         | Show in Finder |

Movies is the default, as in QuickTime Player, also because saving to the Desktop or Documents makes macOS ask the
app for permission to those folders first.

These apply to recordings started from the picker. An option given on the command line wins for that run and is not
remembered: `./screc --gui --quality low` opens the picker with Small quality, and the stored choice stays as it was.
Recordings started on the command line use only their options.

## Saving

Recordings are named `Recording-<date>-<time>.mp4`, and only you can read them. A recording is written elsewhere while
it is being made and appears under its name only once it is complete. An existing file is never overwritten: if the
name was taken in the meantime, the recording is saved as `…-2.mp4` instead.

## Recording from the command line

Any option other than `--gui` switches screc to the command line: it records right away and stops on Ctrl+C. Without
an output file or `--output-dir`, the recording is saved in the current directory.

```sh
./screc --display 0                  # the main display
./screc --window Safari              # one window, by text that only its app name or title contains
./screc --region 0,0,1280,720        # part of a display: x, y, width, height in points from the top left
./screc --mic --quality low talk.mp4
./screc --output-dir ~/Movies        # save as Recording-<date>-<time>.mp4 in ~/Movies
./screc --duration 30                # stop by itself after 30 seconds
./screc --list                       # displays, windows and microphones you can choose from
```

Ctrl+C (or `kill`) stops the recording cleanly: the file is closed and playable. If saving seems stuck, a second
Ctrl+C aborts and discards the recording.

| Option               | Meaning                                                                        |
| -------------------- | ------------------------------------------------------------------------------ |
| `--display N`        | Record display `N` (default 0; see `--list`)                                   |
| `--region X,Y,W,H`   | Record part of the display, in points from its top-left corner                 |
| `--window NAME`      | Record one window: a window ID from `--list`, or text that occurs in exactly one window's "App — Title". All-digit arguments must be valid IDs. Ambiguous names are errors. |
| `--mic`              | Also record a microphone (see below)                                           |
| `--mic-device NAME`  | Record this microphone, by part of its name; implies `--mic`                   |
| `--no-cursor`        | Leave the mouse pointer out of the recording                                   |
| `--output-dir DIR`   | Save `Recording-<date>-<time>.mp4` in `DIR` instead of the current directory   |
| `--quality Q`        | `high`, `medium` (default) or `low`                                            |
| `--scale F`          | Resolution multiplier from 0.1 to 1 (default 1, or 0.5 with `--quality low`)   |
| `--bitrate MBPS`     | Video bitrate in Mbps, instead of the one `--quality` picks                    |
| `--fps N`            | Maximum frame rate (default 60)                                                |
| `--hevc`             | HEVC instead of H.264: smaller at the same quality, but less widely supported  |
| `--duration SEC`     | Stop after this many seconds (at most one week)                                |
| `--list`             | List displays, windows and microphones, then exit                              |
| `--gui`              | Open the picker, starting from the other options; with `--region` (and `--display`), that region is selected if available. Otherwise, draw a new region. |
| `-h`, `--help`       | Show the help                                                                  |

An argument that is not an option is the output file.

## Microphone

With `--mic`, or a microphone chosen in the picker's Options menu, the microphone is mixed into the same audio track
as the system audio, so every player plays both.

If your default input is a Bluetooth headset, `--mic` uses the Mac's built-in microphone instead. A Bluetooth
headset switches to its low-quality call mode as soon as its microphone is in use, and everything you hear through it
then sounds worse until the recording ends. If you do want the headset's microphone, choose it with `--mic-device` or
in the Options menu. `--list` shows which microphone `--mic` would use.

## File size

When a recording starts, screc estimates its size per hour, and the picker shows the same estimate.
For a 1800 × 1169-point Retina display recorded in full:

| Settings          | Resolution  | Video bitrate | One-hour estimate |
| ----------------- | ----------- | ------------- | ----------------- |
| `--quality high`  | 3600 × 2338 | 25.3 Mbps     | 11.4 GB           |
| default           | 3600 × 2338 | 12.6 Mbps     | 5.8 GB            |
| `--hevc`          | 3600 × 2338 | 7.6 Mbps      | 3.5 GB            |
| `--quality low`   | 1800 × 1168 | 3.2 Mbps      | 1.5 GB            |

Actual file sizes vary. The encoder often uses less than its target bitrate for content that barely moves, and the
MP4 container adds some overhead. When a recording ends, screc prints its actual size and the hourly rate it worked
out to.

## More

- [How it works](docs/how-it-works.md): the capture pipeline and the reasons behind its design
- [Troubleshooting](docs/troubleshooting.md)
- [AGENTS.md](AGENTS.md): how the code is organised, conventions, and how to test changes

## Development

```sh
make test                      # tests that need no screen
SCREC_UI_TESTS=1 swift test    # also tests that put windows on the screen for a moment
```

Add `SCREC_SNAPSHOT_DIR=/some/directory` to the second command to get pictures of the picker, its Options menu and
the stop panel as they render. Recording itself needs the screen recording permission and someone to look at the
result, so it is not covered by the tests. See [AGENTS.md](AGENTS.md) for the layout of the code.

## License

[MIT](LICENSE)
