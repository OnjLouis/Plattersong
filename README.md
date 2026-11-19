# Plattersong for Mac

Hear physical disk reads and writes as short, adjustable stereo clicks.
Plattersong runs in the menu bar and provides native keyboard and VoiceOver
controls for each disk's volume, pan, three-band EQ, and independent read and
write pitch.

Requires macOS 13 or later. The universal app supports Apple Silicon and Intel.
See [the manual](Manual.html) for set-up, shortcuts, login and updates.

## Build

With the macOS SDK and Swift compiler available, run:

```sh
bash Build.sh /path/to/a/fresh/build-directory
```

For production packaging, set `SIGN_IDENTITY` to the appropriate Developer ID
Application certificate. The built-in updater intentionally accepts only the
official Developer ID and bundle identifier. It expects a notarized universal
ZIP named `Plattersong-VERSION-macOS.zip` under a `vVERSION` release tag.

## Credits

The click synthesis was adapted from Sensor Readout 6.6.1. See
[the licence](LICENSE.txt).
