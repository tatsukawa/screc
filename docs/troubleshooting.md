# Troubleshooting

## "screen recording is not permitted"

macOS has not allowed the terminal app to record the screen. Open **System Settings → Privacy & Security →
Screen & System Audio Recording**, turn on the terminal app you run screc from (Terminal, iTerm2, …), then quit and
reopen that app. A terminal that was already open when you allowed it keeps failing until it is restarted.

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
text you give, ignoring case. When several windows match, screc records the front-most one and says so; give a
window ID from `--list` to pick another.
Only windows that are on screen can be recorded, so a minimised window or one on another Space does not appear.

## "--region lies outside the display or is too small"

A region is given in points, not pixels, from the top-left corner of the display chosen with `--display`. On a Retina
display, a point is two pixels. `screc --list` shows each display's size in points. A region has to be at least
16 × 16 points.

## "… already exists"

screc never overwrites a file. Give another output name, or move the old file away.

## "the recording was interrupted"

ScreenCaptureKit stopped the capture on its own, and screc printed the reason it gave. Everything recorded until then
has been saved.

## The microphone ended up on a separate audio track

After the recording, screc mixes the microphone into the system audio track. If that step fails, it says so and leaves
the file with two audio tracks, so nothing is lost. Players that only play the first track will then play the system
audio alone; a video editor shows both.
