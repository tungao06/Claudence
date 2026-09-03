# Claudence

A macOS menu bar application that monitors Claude Code sessions. It shows every
active session at once, across every project, with token consumption and the
remaining usage limits.

Claude Code's own status line sees only the session it runs inside. Claudence
sees all of them, which is the reason it exists.

Everything it reads is already on this machine. Two outbound requests exist and
both are on the usage-limit path: `GET api.anthropic.com/api/oauth/usage`, and a
conditional token refresh against `platform.claude.com` when the access token has
expired. Nothing else leaves the machine. `Claudence_CLAUDE.md` holds the full
privacy contract, including the allowlist of fields the transcript parser is
permitted to read.

## Requirements

| | |
|---|---|
| macOS | 14.0 or later (developed on 26.6) |
| Swift | 6.0 toolchain or later (developed on 6.3.3) |
| Xcode | not required, and not used |

Only the Command Line Tools are needed. Everything below runs through Swift
Package Manager and a shell script; there is no `.xcodeproj` and `xcodebuild` is
never invoked.

If `swift --version` fails, install the toolchain with:

```
xcode-select --install
```

## First-time setup

Run this once, before the first build:

```
./Scripts/make-signing-cert.sh
```

It creates a single self-signed code signing certificate named `Claudence Dev`
in your login keychain. macOS will ask for your keychain password.

This matters more than it looks. Claudence reads Claude Code's OAuth token from
the Keychain (service `Claude Code-credentials`). An ad-hoc signature changes on
every build, so macOS treats each build as a different application and re-asks
for Keychain access every single time. One stable certificate makes the "Always
Allow" grant stick across rebuilds.

`Scripts/make-app.sh` finds the certificate on its own, so no environment
variable is needed afterwards. To use a different identity, set
`CODESIGN_IDENTITY` to its name or SHA-1 hash.

If you skip this step the build still succeeds; it signs ad-hoc and prints a
warning saying so.

## Build and run

```
make run
```

That builds the release binary, assembles `Claudence.app`, signs it, and opens
it. The application has no Dock icon and no main window: look for the ring mark
in the menu bar, at the right-hand end.

The individual targets:

| Command | What it does |
|---|---|
| `make build` | Debug build of the SPM products only. No `.app`. |
| `make app` | Release build, then assembles and signs `Claudence.app`. |
| `make run` | `make app`, then `open Claudence.app`. |
| `make install` | `make app`, then copies the bundle into `/Applications`. |
| `make dmg` | Builds `Claudence-<version>.dmg` for another Mac. |
| `make pkg` | Builds an unsigned installer `Claudence-<version>.pkg`. |
| `make icon` | Regenerates `Resources/AppIcon.icns`. |
| `make test` | Runs the Swift Testing suite. |
| `make test-only FILTER=EngineTests` | Runs one suite. |
| `make clean` | Removes `.build`, `Claudence.app`, and any built `.dmg`/`.pkg`. |

`make test` carries a block of extra flags. Swift Testing ships inside Xcode, so
with Command Line Tools alone the framework and its interop dylib have to be
pointed at explicitly or `swift test` fails on `no such module 'Testing'`. The
Makefile does this; a bare `swift test` will not work here.

Only one Claudence runs at a time. If a copy is already running, a second
launch prints which one is running and exits without starting, so `make run`
while the installed copy is up appears to do nothing; that is the guard, not a
failure. Quit the running copy first if you meant to replace it.

To quit the application, use Quit in the menu bar popover, or:

```
pkill -f "Claudence.app/Contents/MacOS/Claudence"
```

### Running two builds at once

Concurrent builds serialise on the `.build` directory lock. Give each one its
own scratch path:

```
swift build --scratch-path .build-alt
```

## Versions

Two numbers, and only one of them is a decision.

| | Where it comes from | When it changes |
|---|---|---|
| `CFBundleShortVersionString` | `Resources/Info.plist`, edited by hand | when you decide a release means something |
| `CFBundleVersion` | `git rev-list --count HEAD`, stamped at build | every commit, automatically |
| `ClaudenceSourceRevision` | `git rev-parse --short HEAD`, stamped at build | every commit, automatically |

`make app` stamps the last two into the copy of `Info.plist` inside the bundle.
It never writes back to `Resources/Info.plist`, so building leaves the working
tree clean and two people building the same commit get the same numbers without
coordinating.

**Before a release, do one thing:** edit `CFBundleShortVersionString` in
`Resources/Info.plist`.

```
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.2.0" Resources/Info.plist
git commit -am "release 0.2.0"
make app
```

The build number takes care of itself. It only has to go up and to differ
between two bundles a friend might both have, and the commit count does both
without a state file that would go stale.

`ClaudenceSourceRevision` carries `-modified` when the working tree was dirty at
build time. It never appears on screen; it goes in the problem report, and it is
the only thing that can tell apart two bundles that both call themselves
`0.1.1 (72)` and were built from different trees. Self-distribution has no build
server to ask.

Both can be overridden for one build without touching any file:

```
MARKETING_VERSION=0.2.0-rc1 BUILD_NUMBER=9001 make app
```

Outside a git checkout — a source tarball, say — the build number stays whatever
`Resources/Info.plist` says, rather than a number invented on the spot that could
go backwards.

There is no update check and there never will be one; see `CLAUDE.md`. A new
version reaches a friend as a new `.dmg` and nothing else.

## Installing

`make run` opens the app straight out of the repository, which is fine for a
build-and-look loop. For everyday use, install it:

```
make install
```

That builds, copies the bundle to `/Applications/Claudence.app`, clears the
quarantine flag, and verifies the signature. A copy already running from that
path is quit first, because replacing a bundle underneath a live process leaves
it running from a deleted inode and the two versions then disagree.

To install for one user only:

```
DEST=~/Applications make install
```

The destination is not cosmetic. Launch at login goes through `SMAppService`,
and macOS is entitled to refuse a login item for an application living in a
build directory. From `/Applications` the registration has a stable path to
point at. The Settings panel reads the real registration status back rather than
assuming success, so if macOS refuses, the panel says so.

After installing, turn on Launch at Login in Settings -> Appearance if you want
it. macOS may put the item in Login Items behind an approval prompt the first
time; that is `requiresApproval`, and the panel reports it under that name.

To uninstall:

```
rm -rf /Applications/Claudence.app
rm -rf ~/Library/Application\ Support/Claudence
defaults delete com.tungao.claudence
```

The second line removes the collected history; the third removes preferences.
Neither touches anything under `~/.claude`.

### Moving it to another Mac

```
make dmg   # Claudence-0.1.0.dmg, drag-to-Applications layout
make pkg   # Claudence-0.1.0.pkg, for a non-interactive install
```

The `.dmg` opens as the usual install window: the app on the left, an
Applications alias on the right, an arrow between them, on a background drawn by
`Scripts/make-dmg-art.swift`. Dragging one onto the other installs it.

Building that layout means letting Finder arrange a mounted volume over
AppleScript, because the arrangement lives in the volume's `.DS_Store` and
Finder is the only thing that writes one. macOS therefore asks once whether the
terminal may control Finder. Refusing is not fatal: the script says so and
carries on, and the image still installs correctly, just with Finder's default
layout. The permission lives in System Settings -> Privacy & Security ->
Automation.

Both files carry the same bundle. Prefer the `.dmg`: it shows the receiving user
what they are copying, and it needs no administrator password. The `.pkg` exists
for the case where an install has to run from a script:

```
sudo installer -pkg Claudence-0.1.0.pkg -target /
```

**Neither is notarised, and neither can be.** Notarisation requires a paid Apple
Developer account, which this project deliberately does not have; the signing
identity from `make-signing-cert.sh` is self-signed and Gatekeeper does not
accept it from another machine. The consequences are specific:

- The `.app` from the `.dmg` will be refused on first launch. The receiving user
  right-clicks it and chooses Open, or runs
  `xattr -dr com.apple.quarantine /Applications/Claudence.app`.
- The `.pkg` cannot be installed by double-clicking at all, because a
  self-signed identity is not accepted for installer packages the way it is for
  application bundles. The `installer` command above works.
- On the receiving Mac, Claudence asks for Keychain access to Claude Code's
  credentials on first run. That is the normal grant, and it sticks as long as
  that machine keeps the same copy of the bundle.

Tell whoever receives the image about the first point before they meet the
dialog cold. If a build needs to install cleanly on Macs you do not control,
that is the point at which a Developer ID and notarisation stop being optional.

## The application icon

The icon is a power meter — the product's governing metaphor — over the warm
plate the interface uses, with three bars inside standing for the several
sessions the application watches at once.

It is committed as `Resources/AppIcon.icns` and copied into the bundle by
`Scripts/make-app.sh`, so an ordinary build needs no icon tooling. Because
`LSUIElement` is set, the icon never appears in the Dock; it shows in Finder, in
notifications, in the Settings window, and in the Force Quit list.

To change it, edit the geometry in `Scripts/make-icon.swift` and regenerate:

```
./Scripts/make-icon.sh
```

That renders all ten sizes an `.icns` needs and runs `iconutil`. Commit the
resulting `Resources/AppIcon.icns`.

The icon is drawn in CoreGraphics rather than rasterised from an SVG, because no
SVG rasteriser is guaranteed present on a machine with only Command Line Tools.
`Resources/Icon/AppIcon.svg` is kept as the design reference and is not part of
the build.

After a rebuild the Finder may keep showing the old icon; that is its cache, not
the bundle. `touch Claudence.app` usually clears it.

## Command line flags

The binary exits before starting the menu bar UI when given any of these, so
they are safe to run while the application is already open.

```
Claudence.app/Contents/MacOS/Claudence --diagnose
```

Prints what each data source resolved to: the session registry, the transcripts,
the Keychain read, and the usage endpoint. This is the first thing to run when
the interface shows fewer sessions than expected.

```
Claudence.app/Contents/MacOS/Claudence --diagnose --raw-usage
```

Prints the unmodified usage response, for when a limit reads wrong and the
question is whether the value or the rendering is at fault.

```
Claudence.app/Contents/MacOS/Claudence --diagnose --counters [seconds]
```

Runs the real registry watcher for the given interval and reports the engine's
own cost separately from the process total. Use it to attribute idle CPU.

```
Claudence.app/Contents/MacOS/Claudence --render-ui <directory>
```

Renders the views offscreen into that directory, for inspecting a layout without
driving the live application by hand.

## Where it keeps things

| Path | What |
|---|---|
| `~/Library/Application Support/Claudence/claudence.db` | Token totals, daily rollups, transcript read cursors. |
| `~/.claude/sessions/`, `~/.claude/projects/` | Claude Code's own files. Read only, never written. |

Deleting `claudence.db` resets the history and forces a full re-scan of every
transcript. Nothing in Claude Code's own directories is affected.

## Troubleshooting

**The Keychain prompt returns after every build.** The build is signing ad-hoc.
Run `./Scripts/make-signing-cert.sh`, then `make app`, and check that it prints
`signed with: <hash>` rather than the ad-hoc warning.

**`security find-identity` does not list `Claudence Dev`.** Expected. A
self-signed certificate is not a "valid" identity for that filter, so it is
absent from the list even though `codesign` accepts it. Check with
`security find-certificate -c "Claudence Dev"` instead.

**`no such module 'Testing'`.** You ran `swift test` directly. Use `make test`.

**Launching it does nothing.** A copy is already running; the second launch
exits on purpose. `pgrep -lf "Claudence.app/Contents/MacOS/Claudence"` says
which one, and its path says whether it is the installed copy or one still
running out of the repository.

**The menu bar shows no sessions.** Run `--diagnose`. Note that `ps` is a poor
cross-check: most processes named `claude` are helpers rather than sessions, so
counting them overstates the real number roughly fourfold.

**Usage reads `Usage unavailable`.** Either the Keychain read was denied or the
usage request failed. Both are ordinary states rather than errors, and the
application will not invent a number to fill the gap. `--diagnose` says which
one happened.

## Measuring idle CPU

`ps -o %cpu` reports a lifetime average and will hide a real regression. Measure
a delta instead, against a warm process with an idle window:

```
PID=$(pgrep -f "Claudence.app/Contents/MacOS/Claudence" | head -1)
date +%s; ps -o time= -p $PID    # wait 5+ minutes, then repeat
# idle % = (cpu2 - cpu1) / (wall2 - wall1) * 100
```

The budget is under 0.5%. A measurement taken while agents are writing
transcripts reports the cost of real work, not idle cost.

## Repository layout

```
Sources/ClaudenceCore/        domain model, transcript parser, engine, store
Sources/Claudence/            SwiftUI menu bar app, dashboard, settings
Tests/                        Swift Testing suites, including the privacy allowlist test
Scripts/make-app.sh           assembles and signs Claudence.app
Scripts/install.sh            copies the bundle into /Applications
Scripts/make-dmg.sh           builds a .dmg for another Mac
Scripts/make-dmg-art.swift    draws that image's window background
Scripts/make-pkg.sh           builds an unsigned installer .pkg
Scripts/make-icon.sh          regenerates Resources/AppIcon.icns
Scripts/make-icon.swift       draws the icon at every size
Scripts/make-signing-cert.sh  one-time self-signed identity
Resources/                    Info.plist, AppIcon.icns, icon design reference
Design/                       UI contract and the design canvas it came from
```

## Further reading

- `Claudence_CLAUDE.md` — product and engineering specification. Authoritative on
  product decisions, data contracts, and the privacy allowlist.
- `CLAUDE.md` — operational summary, including the traps that cost real time.
- `PLAN.md` and `PLAN-UI.md` — milestone trackers.
- `Design/UI-CONTRACT.md` — what the interface is required to look like.
