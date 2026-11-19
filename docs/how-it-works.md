# How screc works

screc is a thin layer over ScreenCaptureKit. This page follows a recording from the moment the user chooses what to
record until the file is closed, and explains the choices made along the way.

```
command line ─┐
              ├─► Options ──► record() ──► SCStream ─────► MovieWriter ──► .mp4
GUI picker ───┘                            (ScreenCaptureKit) (AVAssetWriter)
                                             video frames      H.264 / HEVC
                                             system audio      AAC
                                             microphone              │
                                                                     ▼  only with a microphone
                                                              mixAudioTracks ──► one audio track
```

## One entry point for recording

Both interfaces end in the same function. The command line parses its arguments into an `Options` value
(`Options.swift`); the GUI builds the same kind of value from what the user picks on screen. Neither records anything
on its own: they hand the `Options` to `record(_:control:)` in `Recorder.swift`. A bug in recording therefore shows up
in both interfaces, and a fix fixes both.

## Capturing

`record()` asks ScreenCaptureKit for the displays and windows that can be captured, and turns the options into a
content filter:

- **Display**: a filter for the whole display, minus every window of screc itself (the stop panel, and picker
  overlays that may still be on screen).
- **Region**: the same display filter, with `sourceRect` set to the region. Regions are in points, measured from the
  top-left corner of the display, which is the coordinate space ScreenCaptureKit uses.
- **Window**: a filter for that one window, which keeps working when the window moves or is covered.

What the GUI picked is passed on by ID: the display's ID and the window's ID. Display numbers can change while the
picker is open, for example when a display is connected, and a vanished window must not be replaced by another one
whose title happens to contain its number. If the picked display or window is gone, recording does not start. On the
command line, `--window` takes an ID or text that occurs in exactly one window's name; a name that matches several
windows is an error rather than a guess, because the wrong window may show something private.

The stream configuration asks for the system audio (`capturesAudio`) at 48 kHz stereo. This single setting is what
makes a virtual audio device unnecessary. With a microphone, it also sets `captureMicrophone` and the device to use.
The cursor is included.

## Encoding

ScreenCaptureKit can write a file by itself (`SCRecordingOutput`), but that offers a choice of codec and file type and
no bitrate setting. screc instead receives the samples and encodes them with its own `AVAssetWriter`
(`ScrecMedia/MovieWriter.swift`), which is what makes the quality presets, `--bitrate` and the size estimate possible.

ScreenCaptureKit marks every video sample with a status, and samples marked idle carry no new picture because the
screen did not change. `MovieWriter` writes only samples with a new picture, so a still screen costs almost nothing,
and the file has a variable frame rate capped by `--fps`. The file starts at the first video frame; audio that arrives earlier is dropped.
When the recording stops, the last picture is written once more at the moment of the stop, so that the video lasts as
long as the recording even if nothing changed on screen at the end.

If the encoder fails while recording (for example because the disk is full), `MovieWriter` reports it at once, and the
recording stops instead of running on while nothing is saved.

### Resolution and bitrate

`VideoPlan.swift` turns the size of the recorded area into the encoding settings:

- The resolution is the area in points times the display's backing scale factor (2 on Retina), times the quality's
  scale (½ for `low`) or `--scale`, rounded to even numbers for the encoder.
- The video bitrate is the number of output pixels times 1.5 bits (3 for `high`), times 0.6 for HEVC, and never below
  300 kbps. `--bitrate` replaces this figure.
- Audio is AAC at 160 kbps.

The size estimate is simply (video bitrate + audio bitrate) × one hour. It is an upper bound: the encoder uses less
than its target when little changes on screen.

## The microphone

The microphone arrives as a second audio stream and is written to a second audio track. Many players only play the
first audio track, so once the file is closed, `mixAudioTracks` (`ScrecMedia/AudioMix.swift`) mixes both tracks into
one. It copies the video as it is, without re-encoding it, into a new file with a unique name, and then swaps the two.
If mixing fails, the recording keeps its two tracks and nothing is lost.

When no microphone is named, screc uses the system's default input, except when that is a Bluetooth device and the Mac
has a built-in microphone (`Microphones.swift`). A Bluetooth headset can only use its microphone in its call mode,
which also lowers the quality of everything the user hears. That happens with any app that opens the microphone, but
users do not expect a screen recorder to do it.

## Stopping

A recording runs until something calls `Control.stop()`: Ctrl+C or `kill` on the command line, the Stop button in the
GUI, or the `--duration` timer. The first signal is caught rather than allowed to end the process, so the file is
closed properly; a second one aborts at once and discards the recording, for when saving hangs. The signal handlers run
on their own queue, so they work even while the main thread is busy, and the previous signal handlers are restored when publishing ends.
If ScreenCaptureKit stops the stream on its own, the recording ends the same way, and what was recorded until then is
saved.

## Saving

`OutputFile.swift` decides where the recording goes. While it is being made, it is written into a directory created for
it alone, on the same volume as the destination. Only when the file is complete (and its audio mixed) is it moved to
its final name, with a rename that fails instead of replacing anything that exists (`renamex_np` with `RENAME_EXCL`).
So:

- an unfinished or failed recording never appears under the final name;
- nothing is overwritten, and a symbolic link at the destination is never followed;
- screc only ever deletes what it created itself;
- if the name was taken while recording, the next free name (`…-2.mp4`) is used instead.

The published file is readable by its owner only (mode 0600), since a screen recording can show anything that was on
the screen.

## The picker

The picker (`GUI/`) covers every display with a borderless, translucent window (`OverlayView`) and puts the toolbar
on the display the pointer was on.

- **Model and views.** What is selected, and how a region moves and resizes, is computed in `PickerModel`, which does
  not use AppKit and is covered by unit tests. The views only translate mouse events into model calls and draw the
  result.
- **Coordinates.** The model uses points with the origin at the top left, like ScreenCaptureKit, so a selection can be
  handed to `record()` without conversion. AppKit's window frames have their origin at the bottom left; they are only
  used to place the overlay windows.
- **One display per region.** A recording covers a single display. When a region is dragged onto another display, it
  moves there completely, shrinking if that display is smaller.
- **Clicks on transparent areas.** The inside of a selection is cut out of the dimming and fully transparent. macOS
  sends clicks on transparent pixels to the window below unless the window explicitly accepts mouse events, so the
  overlay sets `ignoresMouseEvents = false`. Without it, a region could not be grabbed.
- **Keys.** Enter and Esc are caught for the whole app, because whichever display's overlay is in front holds the key
  focus.
- **Window level.** The overlays sit above the menu bar and the Dock, but just below pop-up menus, so the Options menu
  opens in front of them.

## The stop panel

During a recording from the GUI, a panel at the top of the screen shows the elapsed time and a Stop button, and the
menu bar has the same button (`RecordingIndicator.swift`). The panel does not take the keyboard focus from the app
being recorded, and it can be dragged out of the way.

The panel is left out of the recording together with every other window of screc, by excluding screc as an
application from the capture. ScreenCaptureKit only lists applications that have a window on screen, so the panel is
shown before the recording starts. Should screc not be listed, the panel is excluded by its window ID instead.

## Settings

Every setting is in the toolbar's Options menu, as in ⌘⇧5; a separate settings window was tried and dropped, because
it left screc with a window that could get lost behind other apps. `Preferences.swift` holds the settings. They are
stored in the `screc` defaults domain, which the app and the binary run from a terminal share. The domain is
deliberately not the app's bundle identifier: a process may not use its own bundle identifier as a suite name, and the
bare binary has none.

The picker starts from the stored settings, overridden by whatever the command line gave (`Options.given` records
which options were given). A choice in the menu changes the picker's settings and stores only that one setting, so an
option given for one run is never saved by accident. A recording started on the command line does not read the stored
settings at all.

## The app

`Packaging/build-app.sh` (`make app`, `make dmg`) wraps the same release binary in `screc.app`, a regular app: it
shows the picker when opened and stays open between recordings. `GUISession` moves between choosing, recording and
waiting; from a terminal it quits after one recording instead. Running as an app changes a few things in the program
(`openedAsApp`):

- While it runs it has a Dock icon and a menu bar, so it can be found, brought back and quit. A first version hid both,
  like the toolbar of ⌘⇧5, and users could not tell whether screc was running at all. Run from a terminal, it still
  has neither: the terminal shows what is going on.
- File → New Recording (⌘N), the Dock icon, and the Dock icon's menu start the next recording. That menu offers Stop
  Recording while recording, and quitting (⌘Q) while recording stops and saves first.

- Errors are also shown in a dialog, since an app opened from Finder has no terminal (`showsFailuresInDialog`). A
  missing screen recording permission offers to open the right pane of System Settings.
- The permission message names the app rather than the terminal, when the app was opened by launchd (Finder, the Dock,
  Spotlight). The binary inside the app, run from a terminal, still depends on the terminal's permission.
- Opening the app again while it runs, or clicking its Dock icon, brings back what it is showing: the picker, the stop
  panel, or a dialog.
- Dialogs do not hide when screc is not the active app. A panel normally does, and an app opened from Finder is not
  always allowed to become active; an error dialog then waited invisibly.

The app is signed with the hardened runtime, which notarization requires, and with the one entitlement it needs under
it: microphone input. The binary is universal (Apple silicon and Intel).

The icon, `Packaging/AppIcon.icon`, is an Icon Composer document: a background colour and two shapes in SVG, with no
drawn effects. `actool` compiles it into `Assets.car`, from which macOS 26 and later draw it as Liquid Glass and adapt
it to the light, dark, tinted and clear appearances, and into `AppIcon.icns` for macOS 15 to 25. The repository holds
no binary artwork.

## Code layout

| Target       | Contains                                                                          |
| ------------ | --------------------------------------------------------------------------------- |
| `screc`      | `main.swift`, one line that calls `runScrec()`                                    |
| `ScrecKit`   | Options, settings, choosing what to record, `record()`, and the GUI               |
| `ScrecMedia` | `MovieWriter` and `mixAudioTracks`, the only code that uses AVAssetWriter/Reader |

`ScrecMedia` is a separate target for one reason. The AVAssetWriter and AVAssetReader methods it uses are deprecated
in macOS 27, and their replacements do not exist on macOS 15 to 26. Compiler warnings are silenced for this target
only, so they cannot hide real warnings elsewhere.
