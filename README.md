# MyTimer

A menu-bar-only macOS timer you set by pulling. Press the timer icon in the menu bar and drag away from it: a rubber-band line stretches from the icon to the cursor, and the pull distance sets the duration — a short pull gives minutes, a pull to about the center of the screen gives ten hours. While pulling you see the value next to the cursor (minutes for short timers, the absolute fire time such as `17:30` for long ones). Release to arm the timer: the band snaps back into the icon with a ripple, and the menu bar switches to a live countdown (`40m`, `9h59m`, seconds during the last minute).

## Features

- Drag-to-set with a smooth exponential distance-to-duration curve (1 minute at ~20 px, ~10 hours at screen center), 1-minute steps under an hour, 5-minute steps above
- Gradient rubber-band line growing from the icon glyph, with sag that tightens as you pull, a knob under the cursor, and a floating blurred value bubble
- Haptic tick plus a subtle pulse ring from the knob on every value change, snap-back and ripple animation on release, fade-out on cancel
- Release close to the icon (under 20 px) to cancel — the band turns red while in the cancel zone
- Click without dragging for a menu that drops below the icon: active timers with fire time and time left, per-timer delete, manual entry (`90` for minutes or `17:30` for a wall-clock time), launch-at-login toggle, quit
- Sound (Glass) plus a user notification when a timer fires, with a floating alert as fallback
- Multiple simultaneous timers; the menu bar shows the soonest one
- Timers persist across relaunches; expired ones are cleaned up on start
- Registers itself as a login item on first launch (toggle it off in the menu)
- Near-zero idle cost: the countdown timer runs only while timers exist, and animation display links run only during animations

## Build and run

```sh
./build.sh
ditto MyTimer.app /Applications/MyTimer.app
open /Applications/MyTimer.app
```

Requires macOS 14 or later. The bundle is assembled by `build.sh` from a SwiftPM release build and ad-hoc codesigned. Install into `/Applications` so the login item survives repository moves and the notification center can read the bundle icon (`Assets/Assets.car` is prebuilt from `Assets/Assets.xcassets`; regenerate with `actool` if the artwork changes).

## macOS 26/27 status-item note

The app never assigns `NSStatusItem.menu` — on recent macOS that would hand all mouse handling to AppKit and break drag tracking. Instead the status button sends `leftMouseDown` to the app, which installs paired local and global `NSEvent` monitors for drag and mouse-up events. The pull only engages once the cursor leaves the menu bar by 10 px; releasing while still inside the bar always opens the menu, so plain clicks stay reliable. A watchdog aborts tracking if the system swallows the mouse-up.

## Development

`MyTimer.app/Contents/MacOS/MyTimer --selftest` verifies the distance mapping, formatting, and manual-entry parsing. With `MYTIMER_DEBUG=1` in the app's environment, it logs state changes to `$TMPDIR/mytimer-debug.log`, and `--send-add-seconds N`, `--send-clear`, and `--send-write-frame` drive a running instance through distributed notifications.
