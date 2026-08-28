# DeskStats

A small always-on desktop widget for Apple Silicon Macs. Per-core CPU load, GPU
utilisation, memory, power draw and charging rate — in a 212×212 card that looks
like it came with the OS.

<img src="docs/screenshot.png" width="320" alt="DeskStats widget">

## What it shows

| | |
|---|---|
| **FPS** | Display presentation rate — tracks a fullscreen game's output (see caveat) |
| **Watts used** | System draw, derived from adapter input minus what the battery absorbs |
| **CPU** | One bar per core, performance cores separated from efficiency cores |
| **GPU** | Device utilisation, with renderer and tiler broken out beneath |
| **MEM** | Active + wired + compressed, the way Activity Monitor counts it |
| **Power** | Charging or draining rate, negotiated adapter wattage, and the PD ceiling |

Multi-port aware: it reads the full `AppleRawAdapterDetails` array, so if more
than one source is connected it reports which one macOS selected and how many
are present.

## Install

```sh
./install.sh
```

Builds the app, copies it to `~/Applications`, and registers a LaunchAgent so it
starts at login. `./build.sh` alone just produces `build/DeskStats.app`.

## Controls

| Action | Result |
|---|---|
| Drag | Move it anywhere |
| Double-click | Slide off the nearer edge, leaving 10% visible; again to restore |
| Single-click | Toggle mini mode — FPS and the three load gauges only |
| **Triple-click** | **Quit outright — the process is gone, not just the window** |
| Right-click | Placement, FPS toggle, launch-at-login, quit |
| ⌃⌥⌘D | Cycle placement — the way back out of click-through mode |
| `stats` | Bring it back up from any terminal |

### Exams and proctoring

Triple-clicking terminates the process cleanly, exiting with status 0. The
LaunchAgent's `KeepAlive` rule only restarts on a *failed* exit, so a deliberate
quit is respected and nothing respawns — which is what proctoring software like
LockDown Browser expects to see. `stats` brings it back afterwards:

```sh
stats          # toggle: starts if down, stops if up
stats on       # start
stats off      # stop
stats status   # report
```

Stopping goes through AppKit's quit so the exit status is 0. This matters more
than it looks: `KeepAlive` restarts on a *failed* exit, so `pkill` reads as a
crash and gets respawned, while a clean quit is respected.

While peeked off-screen it drops from a 1 s to a 5 s sample interval, since
there is nothing to look at.

Click actions are deferred by one `doubleClickInterval` so a further click
cancels the previous one, and a drag cancels whatever is pending.

Three placements: **On Desktop** (pinned to the wallpaper, under every window),
**Float Above Windows** (default), and **Game Overlay** — above the shielding
window level so it composites over fullscreen apps, with clicks passing through
to the game underneath. Note that click-through means the widget is completely
inert in this mode: ⌃⌥⌘D is the way back out.

## Behaviour

Designed to be invisible when it is not wanted:

- **Holds no power assertions.** Never prevents sleep, display sleep or hibernate.
- **Suspends entirely on sleep** and on display sleep; resumes on wake.
- **Sudden termination enabled**, so logout and restart are never delayed.
- **`ProcessType: Background`** — the scheduler throttles it freely.
- Survives reboots via the LaunchAgent; `KeepAlive` restarts it on crash but
  respects a deliberate Quit.
- Repositions itself if the display it lived on is unplugged.

Costs roughly **1.4% CPU and 50 MB** at a 1 Hz sample rate.

That number took measuring. SwiftUI `.animation()` modifiers re-render the whole
card at the display's refresh rate for the animation's duration — on a 240 Hz
panel that alone was 2.1 points of CPU, so the animations are gone. Drop shadows
cost similarly, since each forces an offscreen pass per view per frame; ten
animated core bars with shadows is ten such passes. The `CGDisplayStream` behind
the FPS counter, which I had assumed was the expensive part, measured at roughly
0.2 points.

## Two honest limits

**Per-GPU-core load does not exist on Apple Silicon.** macOS publishes only three
aggregate counters — `Device`, `Renderer` and `Tiler Utilization %`. The widget
shows all three rather than inventing per-core bars. `gpu-core-count` and
`core_mask_list` in the IORegistry are static topology, not live load.

**FPS needs Screen Recording permission, and macOS will say so bluntly.** The
prompt reads "DeskStats is trying to record screen and audio" — that is the
generic TCC string for the ScreenCapture class. The widget captures a 2×2 pixel
surface to count frame callbacks and touches no audio whatsoever. Grant it under
System Settings → Privacy & Security → Screen Recording, or right-click the
widget and switch the FPS counter off to avoid the permission entirely.

Note that an ad-hoc signature (`codesign -s -`) is content-derived, so every
rebuild produces a new identity and macOS re-prompts. Grants stick once you stop
rebuilding.

**FPS is a presentation rate, not an in-process frame counter.** There is no
public API to read another application's frame rate; overlays like RTSS and
MangoHud inject into the graphics API, which requires disabling SIP. DeskStats
instead counts display presentation events via `CGDisplayStream`, which tracks a
fullscreen game's output and is bounded by the display's refresh rate. It needs
**Screen Recording** permission (System Settings → Privacy & Security → Screen
Recording); without it the FPS field reads `––`. For authoritative in-game
numbers, Apple's Metal HUD (`MTL_HUD_ENABLED=1`) is the right tool.

Per-core *temperature* is likewise unavailable — the SMC keys are not readable by
unprivileged processes on Apple Silicon. The temperature shown is the battery
sensor.

## Build

Requires only the Xcode Command Line Tools; there is no Xcode project.

```
Sources/Metrics.swift     IOKit + mach sampling
Sources/FPS.swift         CGDisplayStream frame counter
Sources/WidgetView.swift  SwiftUI presentation
Sources/main.swift        NSWindow shell, placement, lifecycle
```
