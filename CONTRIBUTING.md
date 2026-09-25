# Contributing to MeetingGuru

Thanks for helping. Bug reports, fixes, provider notes and ideas are all welcome.

## Reporting a problem

Open an issue with:

- your macOS version and calendar provider (iCloud, Google, Nextcloud, PrivateEmail, other),
- what you expected and what happened,
- the log around it: `log show --last 10m --predicate 'subsystem == "com.meetingguru.app"'`, or run the app with `--debug`.

Remove server URLs, addresses and event titles you don't want to share. `--show-config` prints your settings with the password and token hidden.

## Setting up

You need macOS 14 or later, Apple silicon and Xcode 16 or later. There are no other dependencies.

```bash
git clone https://github.com/moaddib666/MeetGuru.git
cd MeetGuru
make test
make demo
```

`make demo` runs the app with sample meetings and an invitation, so you can work on the island without a calendar account. `make help` lists every target:

| Target | What it does |
|--------|--------------|
| `make build` | Debug build |
| `make test` | Unit tests (Swift Testing) |
| `make lint` | Checks formatting with `swift format` (the rules are in `.swift-format`) |
| `make format` | Reformats the sources in place |
| `make run` | Runs the debug build against your real calendar |
| `make demo` | Runs with sample data, no network |
| `make gallery` | Renders every island state to `dist/gallery/*.png` |
| `make demo-gif` | Records `docs/images/demo.gif` from the `--demo-tour` script |
| `make app` | Builds `dist/MeetingGuru.app` |
| `make install` / `make uninstall` | Installs into or removes from `/Applications` |
| `make zip` | Packages a release zip with its SHA-256 checksum |

## How the code is laid out

- `Sources/MeetingGuruCore` holds everything that can be tested without a screen: CalDAV discovery and sync, iCalendar parsing and recurrence, invitation detection and replies, the alert rules (`StateMachine`), the island's states (`IslandMachine`) and what each state shows (`IslandPresenter`).
- `Sources/MeetingGuru` is the AppKit and SwiftUI app: the island panel and view, the menu bar item, Settings, and `AppController`, which ties them together on a one-second tick.
- `Tests/MeetingGuruCoreTests` covers the core. CalDAV tests run against a scripted fake server (`FakeTransport`), so they need no network.

New behaviour belongs in the core with tests. Keep the app target thin: it should draw a snapshot and forward clicks.

## Changing the island

The island is drawn from an `IslandSnapshot`, so every state can be rendered without clicking through the app:

1. Add or update the state in `Sources/MeetingGuru/Island/Gallery.swift`.
2. Run `make gallery` and look at the PNGs in `dist/gallery`.
3. If the change is visible in the README, refresh the images in `docs/images` and, when the tour changes, run `make demo-gif` (it needs Screen Recording permission for your terminal, plus `ffmpeg`).

Keep the existing visual language: black island, brass for countdowns, coral for lateness and errors, blue for invitations, sentence-case labels that say what the button does.

## Pull requests

- Branch from `main` and keep each pull request to one change.
- Run `make lint test` before pushing, and `make app` if you touched the app target.
- Write commit messages in the imperative (`Add Webex link detection`), with a body explaining why when it isn't obvious.
- Describe how you checked the change, and attach a gallery image or a short recording for anything visual.

By contributing, you agree that your work is released under the [MIT License](LICENSE).
