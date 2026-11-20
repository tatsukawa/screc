# Troubleshooting

## "screen recording is not permitted"

macOS has not allowed screc to record the screen. Open **System Settings → Privacy & Security →
Screen & System Audio Recording** (the app's error dialog has a button for it) and turn on:

- **screc**, if you opened the screc app;
- the terminal app (Terminal, iTerm2, …), if you ran screc from a terminal. A terminal that was already open when you
  allowed it keeps failing until it is restarted.

Then open screc again. After rebuilding the app, the permission may have to be given again: an ad hoc signature changes
with every build, and macOS treats the new build as a different app.

## "screc can't be opened" or "Apple could not verify screc"

The app was built on another Mac, such as the one that made a release, and is not notarized by Apple. If you trust
where it came from, click **Done**, then allow it under **System Settings → Privacy & Security** with **Open Anyway**.
Or build it yourself (`make dmg`); a build made on your own Mac opens without this.

## macOS asks for access to the Desktop or Documents folder

Saving there needs that permission. Allow it, or choose another folder under **Options → Save to**. Movies, the
default, needs no permission.

## "the folder … does not exist"

The folder chosen under **Options → Save to**, or given with `--output-dir`, was moved or deleted. Choose another
one.

## What I hear gets worse while recording

This happens when a Bluetooth headset's microphone is recorded. A Bluetooth headset can only use its microphone in its
call mode, which lowers the quality of everything played through it until the microphone is released.

`--mic` avoids the headset's microphone and uses the Mac's built-in one when there is one. Run `screc --list` to see
which microphone `--mic` picks. In the picker, choose a microphone that is not the headset under Options →
Microphone. Recording without a microphone never changes what you hear.

## The file is tiny, or plays as a still picture

That is expected when little changed on the screen. ScreenCaptureKit only delivers a frame when something on the
screen changes, so a recording of a still screen holds only a few frames and can be just a few kilobytes. The sound
is still recorded for the whole time.

## "there is no display N" or "no window matches …"

Displays are numbered, and windows identified, as `screc --list` shows them. A window name only has to contain the
text you give, ignoring case, but it has to match exactly one window. A number is always taken as a window ID.
Only windows that are on screen can be recorded, so a minimised window or one on another Space does not appear.

## "N windows match …"

The text given to `--window` occurs in the names of several windows. screc does not guess, because the wrong window may
show something private. It lists the matching windows with their IDs; give the ID of the one you mean.

## "the window you picked is no longer on screen" or "the display you picked is no longer connected"

Between choosing in the picker and the start of the recording, the window was closed or minimised, or the display was
disconnected. Start screc again and choose again.

## screc seems to be running, but nothing shows

Click its icon in the Dock, or open it again: it brings back whatever it is showing (the picker, the stop panel or a
dialog). To quit it, use **Quit** in the Dock icon's menu or ⌘Q; a recording in progress is saved first.

## The picker does not respond

If you started screc from a terminal, press Ctrl+C there. That ends screc and removes the dimmed overlay. If you
opened the app, force-quit it (⌥⌘Esc, or `killall screc` in a terminal).

## "--region lies outside the display or is too small"

A region is given in points, not pixels, from the top-left corner of the display chosen with `--display`. On a Retina
display, a point is two pixels. `screc --list` shows each display's size in points. A region has to be at least
16 × 16 points.

## "… already exists"

screc never overwrites a file. Give another output name, or move the old file away. If the name only gets taken while
recording, the recording is saved under the next free name (`…-2.mp4`), and screc says so.

## "cannot save the recording as …"

The finished recording could not be moved to its name. Nothing is lost: the message says where the recording is.

## Saving takes very long

A second Ctrl+C aborts and discards the recording.

## "the recording was interrupted"

ScreenCaptureKit stopped the capture on its own, and screc printed the reason it gave. Everything recorded until then
has been saved.

## The microphone ended up on a separate audio track

After the recording, screc mixes the microphone into the system audio track. If that step fails, it says so and leaves
the file with two audio tracks, so nothing is lost. Players that only play the first track will then play the system
audio alone; a video editor shows both.
