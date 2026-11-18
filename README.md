# screc

Record your Mac's screen **together with the sound it is playing**, without BlackHole or any other virtual audio
device, without a driver, and without anything running in the background.

Recording the screen with system audio has traditionally meant installing a virtual audio device and routing the Mac's
output through it. screc does not need that: it uses only Apple's ScreenCaptureKit, which can capture system audio
directly. Nothing is installed besides the `screc` binary, and nothing is left behind when you delete it.

- Record a whole display, a single window, or a region you draw
- System audio, and optionally a microphone, in a single audio track
- An on-screen picker in the style of ⌘⇧5, or plain command-line options
- An estimate of how large an hour of recording will be, and options to make it smaller
- `.mp4` files in H.264 or HEVC, at the display's full Retina resolution by default

## Requirements

- macOS 15 or later to run
- Xcode 26 or later to build (Swift 6 and the macOS 26 SDK)

screc has only been used on macOS 27 so far. It is written for macOS 15 and later, and the Liquid Glass look of the
picker falls back to a blurred background before macOS 26, but neither has been tried on an older system yet.

## Build

```sh
git clone <this repository>
cd screc
make
```

`make` runs `swift build -c release` and puts a `screc` link in the repository that points to the binary in
`.build/release/`. The binary has no dependencies; copy it onto your `PATH` if you want to run it from anywhere.

## Permission

The first time you record, macOS asks whether your terminal app may record the screen. Allow it in
**System Settings → Privacy & Security → Screen & System Audio Recording**, then quit and reopen the terminal.
The permission belongs to the terminal app (Terminal, iTerm2, …) that runs screc, not to screc itself.

## Recording with the picker

```sh
./screc
```

The screen dims and a toolbar appears near the bottom of it:

| Control                     | Does                                                    |
| --------------------------- | ------------------------------------------------------- |
| ✕                           | Cancel (or press Esc)                                   |
| Display / Window / Region   | What to record                                          |
| Options                     | Microphone and quality                                  |
| Record                      | Start recording (or press Enter)                        |

- **Display**: click the display to record, or press Enter.
- **Window**: move the pointer over a window to highlight it, then click it.
- **Region**: drag out a rectangle. Drag inside it to move it, also onto another display, and drag its edges or
  corners to resize it. Then press Enter or click Record.

The line under the toolbar shows what will be recorded, at which resolution, and at most how much disk space one hour
of it takes. The toolbar can be moved by dragging its edge.

While recording, a panel at the top of the screen shows the elapsed time and a **Stop** button. The menu bar has the
same button. The panel is left out of the recording. When you stop, the panel says "Saved" and the file is shown in
Finder.

If the picker ever stops responding, press Ctrl+C in the terminal you started it from.

Recordings are saved in the directory you started screc from, as `Recording-<date>-<time>.mp4`, and only you can
read them. A recording is written elsewhere while it is being made and appears under its name only once it is
complete. An existing file is never overwritten: if the name was taken in the meantime, the recording is saved as
`…-2.mp4` instead.

## Recording from the command line

Any option other than `--gui` switches screc to the command line: it records right away and stops on Ctrl+C.

```sh
./screc --display 0                  # the main display
./screc --window Safari              # one window, by text that only its app name or title contains
./screc --region 0,0,1280,720        # part of a display: x, y, width, height in points from the top left
./screc --mic --quality low talk.mp4
./screc --duration 30                # stop by itself after 30 seconds
./screc --list                       # displays, windows and microphones you can choose from
```

Ctrl+C (or `kill`) stops the recording cleanly: the file is closed and playable. If saving seems stuck, a second
Ctrl+C aborts and discards the recording.

| Option               | Meaning                                                                        |
| -------------------- | ------------------------------------------------------------------------------ |
| `--display N`        | Record display `N` (default 0; see `--list`)                                   |
| `--region X,Y,W,H`   | Record part of the display, in points from its top-left corner                 |
| `--window NAME`      | Record one window: a window ID from `--list`, or text that occurs in exactly one window's "App — Title" (a name that matches several windows is an error, so that a broad name cannot record the wrong one) |
| `--mic`              | Also record a microphone (see below)                                           |
| `--mic-device NAME`  | Record this microphone, by part of its name; implies `--mic`                   |
| `--quality Q`        | `high`, `medium` (default) or `low`                                            |
| `--scale F`          | Resolution multiplier from 0.1 to 1 (default 1, or 0.5 with `--quality low`)   |
| `--bitrate MBPS`     | Video bitrate in Mbps, instead of the one `--quality` picks                    |
| `--fps N`            | Maximum frame rate (default 60)                                                |
| `--hevc`             | HEVC instead of H.264: smaller at the same quality, but less widely supported  |
| `--duration SEC`     | Stop after this many seconds (at most one week)                                |
| `--list`             | List displays, windows and microphones, then exit                              |
| `--gui`              | Open the picker, starting from the other options; with `--region` (and `--display`), that region is selected |
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

When a recording starts, screc prints the most that one hour of it can take, and the picker shows the same estimate.
For a 1800 × 1169-point Retina display recorded in full:

| Settings          | Resolution  | Video bitrate | One hour, at most |
| ----------------- | ----------- | ------------- | ----------------- |
| `--quality high`  | 3600 × 2338 | 25.3 Mbps     | 11.4 GB           |
| default           | 3600 × 2338 | 12.6 Mbps     | 5.8 GB            |
| `--hevc`          | 3600 × 2338 | 7.6 Mbps      | 3.5 GB            |
| `--quality low`   | 1800 × 1168 | 3.2 Mbps      | 1.5 GB            |

These are upper bounds. ScreenCaptureKit only delivers a frame when something on the screen changes, and the encoder
uses less than its target bitrate for content that barely moves, so real recordings are often much smaller. When a
recording ends, screc prints its actual size and the hourly rate it worked out to.

## More

- [How it works](docs/how-it-works.md): the capture pipeline and the reasons behind its design
- [Troubleshooting](docs/troubleshooting.md)
- [AGENTS.md](AGENTS.md): how the code is organised, conventions, and how to test changes

## Development

```sh
make test                      # tests that need no screen
SCREC_UI_TESTS=1 swift test    # also tests that put windows on the screen for a moment
```

Add `SCREC_SNAPSHOT_DIR=/some/directory` to the second command to get pictures of the picker and the stop panel as
they render. Recording itself needs the screen recording permission and someone to look at the result, so it is not
covered by the tests. See [AGENTS.md](AGENTS.md) for the layout of the code.

## License

[MIT](LICENSE)
