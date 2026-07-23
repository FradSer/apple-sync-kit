# macOS / launchd Background Sync

`note` and `event` can sync automatically in the background via a per-user
launchd LaunchAgent. There is no long-running daemon: launchd starts the CLI
on a fixed interval (`StartInterval`), the CLI runs one full sync
(pull then push) and exits. Overlaps with a manually-started sync are
prevented by the existing flock in `ConfigStore`.

## Quick start

```bash
export NOTE_ENCRYPTION_KEY=<base64 key>   # same key as your other devices
note sync daemon install                  # default: every 1800s (30 min)
note sync daemon status
```

For `event`, swap in `EVENT_ENCRYPTION_KEY` and `event sync daemon ...`.

| CLI | env prefix | config namespace | LaunchAgent label |
|-----|-----------|------------------|-------------------|
| `note`  | `NOTE_`  | `note-sync`  | `ai.fradser.note-sync`  |
| `event` | `EVENT_` | `event-sync` | `ai.fradser.event-sync` |

## Commands

- `<cli> sync daemon install --interval <seconds>` — writes
  `~/Library/LaunchAgents/<label>.plist` (mode `0600`), loads it with
  `launchctl bootstrap`, and kickstarts an immediate run. Idempotent:
  re-running reinstalls with the new settings.
- `<cli> sync daemon status` — launchd state plus the last daemon run
  recorded in `~/.config/<namespace>/last-run.json`.
- `<cli> sync daemon uninstall` — `launchctl bootout` and removes the plist.

## What goes into the plist

- `ProgramArguments`: the resolved absolute path of the running binary
  (symlinks resolved) followed by `sync run --daemon`.
- `EnvironmentVariables`: the encryption key, captured from your shell at
  install time, plus a minimal `PATH`. launchd jobs do **not** inherit your
  shell environment — this is why the key must live in the plist (mode
  `0600`). The API URL/token are not in the plist; they resolve from
  `~/.config/<namespace>/config.json` as usual. If you rotate the key,
  re-run `install`.
- `StartInterval` + `RunAtLoad`: sync runs on load (login/install) and then
  every N seconds. Missed fires during sleep are not replayed; the next
  interval fire catches everything up.
- `ProcessType=Background` + `LowPriorityIO`: keeps the job out of the way
  of interactive work.
- `StandardOutPath`/`StandardErrorPath`: both point at
  `~/.config/<namespace>/logs/daemon.log` (append, no rotation — output is
  a few lines per run).

## The `--daemon` flag

`sync run --daemon` is the same full sync with two behavior changes:

1. If another sync holds the lock (e.g. you ran `note sync` by hand), the
   daemon run prints "another sync in progress, skipping" and exits 0
   instead of failing.
2. At the end it records the outcome (timestamp, pull/push counts, error if
   any) in `~/.config/<namespace>/last-run.json`, which
   `sync daemon status` reads.

## Troubleshooting

```bash
launchctl print gui/$(id -u)/ai.fradser.note-sync   # state, last exit code
tail -f ~/.config/note-sync/logs/daemon.log         # job output
note sync daemon status                             # parsed view + last run
```

If the daemon's syncs fail with a key error, the plist's key is missing or
stale — re-run `<cli> sync daemon install` with `*_ENCRYPTION_KEY` exported.
