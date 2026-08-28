# DeskStats

A small always-on desktop widget for Apple Silicon Macs. Per-core CPU load, GPU
utilisation, memory, power draw and charging rate — in a 212×212 card that looks
like it came with the OS.

<img src="docs/screenshot.png" width="320" alt="DeskStats widget">

## What it shows

| | |
|---|---|
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
| Single-click | Toggle mini mode — power draw and the three load gauges |
| **Triple-click** | **Quit outright — the process is gone, not just the window** |
| Right-click | Placement, mini mode, launch-at-login, quit |
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

Click actions wait `min(doubleClickInterval, 0.35s)` so a following click, or a
drag, can cancel them. Acting on arrival instead was tried and reverted: it
fired mini mode on the way into every drag, and a second double-click undid a
peek that the first click of that pair had already re-stashed, sending the card
further off-screen instead of bringing it back.

Peeking stores only the window's x origin, never a whole frame — a stored frame
goes stale the moment the card resizes between full and mini.

Three placements: **On Desktop** (pinned to the wallpaper, under every window),
**Float Above Windows** (default), and **Game Overlay** — above the shielding
window level so it composites over fullscreen apps, with clicks passing through
to the game underneath. Note that click-through means the widget is completely
inert in this mode: ⌃⌥⌘D is the way back out.

## Behaviour

**Requires no permissions at all** — no Screen Recording, no Accessibility, no
Full Disk Access. Everything comes from IOKit and mach counters that any process
may read.

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
animated core bars with shadows is ten such passes. A `CGDisplayStream`-based FPS counter, which I had assumed was
the expensive part, measured at roughly 0.2 points — it was dropped for needing
Screen Recording permission, not for its cost.

## One honest limit

**Per-GPU-core load does not exist on Apple Silicon.** macOS publishes only three
aggregate counters — `Device`, `Renderer` and `Tiler Utilization %`. The widget
shows all three rather than inventing per-core bars. `gpu-core-count` and
`core_mask_list` in the IORegistry are static topology, not live load.

Per-core *temperature* is likewise unavailable — the SMC keys are not readable by
unprivileged processes on Apple Silicon. The temperature shown is the battery
sensor.

## Build

Requires only the Xcode Command Line Tools; there is no Xcode project.

```
Sources/Metrics.swift     IOKit + mach sampling
Sources/WidgetView.swift  SwiftUI presentation
Sources/main.swift        NSWindow shell, placement, lifecycle
```
