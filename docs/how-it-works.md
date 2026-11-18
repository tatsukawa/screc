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

- **Display**: a filter for the whole display, minus screc's own windows (the stop panel).
- **Region**: the same display filter, with `sourceRect` set to the region. Regions are in points, measured from the
  top-left corner of the display, which is the coordinate space ScreenCaptureKit uses.
- **Window**: a filter for that one window, which keeps working when the window moves or is covered.

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
one. It copies the video as it is, without re-encoding it, and replaces the file. If mixing fails, the recording keeps
its two tracks and nothing is lost.

When no microphone is named, screc uses the system's default input, except when that is a Bluetooth device and the Mac
has a built-in microphone (`Microphones.swift`). A Bluetooth headset can only use its microphone in its call mode,
which also lowers the quality of everything the user hears. That happens with any app that opens the microphone, but
users do not expect a screen recorder to do it.

## Stopping

A recording runs until something calls `Control.stop()`: Ctrl+C or `kill` on the command line, the Stop button in the
GUI, or the `--duration` timer. Signals are caught rather than allowed to end the process, so the file is always
closed properly. If ScreenCaptureKit stops the stream on its own, the recording ends the same way, and what was recorded
until then is saved.

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

The panel is left out of the recording by its window ID. screc asks ScreenCaptureKit only for windows that are on
screen, so the panel is shown first and the recording started afterwards.

## Code layout

| Target       | Contains                                                                          |
| ------------ | --------------------------------------------------------------------------------- |
| `screc`      | `main.swift`, one line that calls `runScrec()`                                    |
| `ScrecKit`   | Options, choosing what to record, `record()`, and the GUI                         |
| `ScrecMedia` | `MovieWriter` and `mixAudioTracks`, the only code that uses AVAssetWriter/Reader |

`ScrecMedia` is a separate target for one reason. The AVAssetWriter and AVAssetReader methods it uses are deprecated
in macOS 27, and their replacements do not exist on macOS 15 to 26. Compiler warnings are silenced for this target
only, so they cannot hide real warnings elsewhere.
