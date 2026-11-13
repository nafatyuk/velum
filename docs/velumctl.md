# velumctl

`velumctl` answers "is everything in the cloud?" from Terminal, for scripts, Raycast and backup jobs. It ships inside the app, at `Velum.app/Contents/MacOS/velumctl`, and only reads: it changes nothing in Velum or in any sync app.

## Install

Link it into `/usr/local/bin`, which is on macOS's own PATH:

```sh
sudo mkdir -p /usr/local/bin && sudo ln -sf ~/Applications/Velum.app/Contents/MacOS/velumctl /usr/local/bin/velumctl
```

Any folder on your PATH works (`~/.local/bin` needs no `sudo`, once it's on your PATH). Jobs run by `launchd` see a short PATH, so give them the full path instead.

## Commands

| Command | Prints |
|---|---|
| `velumctl lid` | One line: "Is it safe to close the lid?", in the panel's words. |
| `velumctl status`, or just `velumctl` | The panel's summary and lid line, then a heading per service with its accounts under it. |
| `velumctl pending` | The lid line, then every file not in the cloud yet: failing first, then oldest; at most 50, with the total. Files failing, or waiting 10 minutes or more, are marked stuck. |
| `velumctl --version` | The app's version and the status schema it reads. |
| `velumctl --help` | Usage and the exit codes. |

Add `--json` to `status`, `lid` or `pending` for the same answer as JSON.

## Exit codes

Every command exits with the lid's answer, so any of them can gate a script:

| Code | Meaning |
|---|---|
| 0 | Safe to close the lid: every change in the watched cloud folders is in the cloud. |
| 1 | Wait: files are on their way up, or a service's own queue is still working. |
| 2 | Not everything is in the cloud: files can't upload, or a sync app isn't running. |
| 3 | Can't tell: Velum can't vouch, isn't running, or its status is out of date or unreadable. While an other cloud folder (beta) is shown, a lid with nothing waiting is 3, never 0: handle 3 apart from 1. |
| 64 | Usage error. |

```sh
velumctl lid >/dev/null && echo "go ahead" || echo "not yet"
```

## Where the answer comes from

The running Velum writes `~/Library/Application Support/Velum/status.json` after every refresh (every 2.5 s). The file is readable by your user only (mode 0600) and is replaced in one step, so a reader never sees half of it. It names files that aren't in the cloud yet, as the panel does; it never leaves your Mac.

`velumctl` answers "can't tell" (exit 3), with nothing else, when:
- there is no file (Velum isn't running, or hasn't finished its first refresh);
- the Velum that wrote it has quit;
- it is older than two refresh intervals (at least 5 s);
- it is dated later than the Mac's clock (by more than a second);
- it can't be read, or is in a newer format than this `velumctl` knows;
- it says "safe" while its own services or accounts say otherwise (an app not running, files waiting or failing, an account Velum doesn't fully watch, a service still working). The app never writes that; `velumctl` checks anyway.

It never falls back on the last good answer. A file can't claim more than 30 s between refreshes, so even a bad one goes stale within a minute.

## JSON, schema 1

Dates are ISO 8601 in UTC with milliseconds (`2026-11-13T06:12:01.234Z`); durations are seconds. Keys are sorted. A key with no value (nothing known, or not applying) is left out.

### The rules
- `schema` goes up only when a key is renamed or removed, a value changes meaning, or a list of values (like `verdict`) gains one. New keys can appear within a schema; ignore the ones you don't know.
- A reader that meets a newer schema answers "can't tell". It never guesses.
- Services, accounts and files are lists of any length. Account keys are Velum's own (`Personal`, `Business1`, `iCloudDrive`, `googledrive:<email>`, `cloudstorage:<folder name>`) and come and go at run time: never assume three services or fixed keys.

### velumctl's output

| Key | |
|---|---|
| `schema` | 1 |
| `fresh` | `true` when the status is current. When `false`, only `lid` follows (with `verdict` `unknown` and the reason), plus `written` and `ageSeconds` when there is a readable file. |
| `written`, `ageSeconds` | When Velum wrote the status, and how many seconds ago. |
| `lid` | The answer; below. `exitCode` is always the verdict's, whatever the file says. |
| `refreshEvery`, `app`, `state`, `summary`, `services`, `accounts` | `status` only. |
| `pending` | `status` and `pending`. |

The status file itself is `velumctl status --json` without `fresh` and `ageSeconds`.

### `lid`

| Key | |
|---|---|
| `verdict` | `safe`, `pending`, `busy`, `failing`, `notRunning` or `unknown`. |
| `files` | `pending`: files on the way up. `failing`: files that can't upload. |
| `service` | `notRunning`: the service whose app isn't running. |
| `account` | `busy`: the account whose service is still working. |
| `reason` | `unknown`: why, and what would end it. |
| `title`, `detail` | The lid line's words. |
| `exitCode` | As above. |

### `refreshEvery`, `app`, `state`, `summary`

`refreshEvery` is the seconds between the app's refreshes. `app` has the app's `version`, `build` and `pid`. `state` is the menu bar icon's: the worst account, or a stopped app (`ok`, `unknown`, `syncing`, `offline`, `paused`, `warning`, `notRunning`, `error`). `summary` is the panel's summary line.

### `services[]`

| Key | |
|---|---|
| `id` | `onedrive`, `icloud`, `googledrive`, `cloudstorage` (other cloud folders, beta); more may come. |
| `name` | As the panel's heading says it. |
| `appRunning` | Left out when there's no app to run (iCloud is part of macOS). |
| `trouble` | A service-wide problem ("Storage full"). |
| `paused` | The service's own pause switch, where Velum reads one (Google Drive). Left out for OneDrive, which pauses per account: that shows as the account's `state`. |
| `compatibility` | `headline` ("OneDrive 26.212 (26.212.1029) · tested · every check passes"), `version`, `tested`, and `checksNotPassing`, how many of the app's internals Velum reads don't read as tested right now. |

### `accounts[]`

| Key | |
|---|---|
| `key`, `service`, `name` | The account, its service's `id`, and its name in the panel. |
| `state`, `headline` | As the row shows them. |
| `detail` | The row's last line: the source with its age, the last change. |
| `source` | Where the headline came from ("Live from macOS", "OneDrive report, 1:45 PM"). |
| `age` | How old that evidence is, in words ("live", "12 min ago"). |
| `old` | The status rests on an old report: never green. |
| `reason` | Why Velum can't tell or can't vouch, and what would end it. |
| `notes`, `notesNeedAttention` | Facts about the account ("Desktop & Documents included · 214 GB free"), and whether the panel shows them in orange. |
| `headlineFromApp` | The headline is the sync app's own words (OneDrive's icon text). |
| `lastChange` | The account's latest sync activity. |
| `uploads` | `pending` (waiting or uploading), `failed`, `stuck` (failing, or waiting at least `pending.stuckAfter`), `oldestWaiting`, `firstFailure` ("<file name>: <reason>"), `covered` (Velum watches all the account's folders with no known gap, so the counts are complete), `serviceBusy` and `serviceBusySince` (the service's own queue holds work that isn't a counted file). |
| `storage` | Bytes: `limit` (left out on an unlimited plan), `used`, `free`, `usedByFiles`, `full`, `asOf`, and `source`: `googleDriveCache` (Google Drive's copy on this Mac), `googleSignIn` (the optional sign-in) or `iCloudQuota` (macOS's `brctl quota`, free space only). |

### `pending`

| Key | |
|---|---|
| `total` | Files not in the cloud yet, listed or not. |
| `stuck` | Of those, failing or waiting at least `stuckAfter` seconds: the panel's "Not in the cloud yet". |
| `stuckAfter` | 600 unless changed for testing. |
| `files[]` | At most 50, failing first, then oldest: `account` (its key), `path`, `name`, `since` (its latest change), `status` (`waiting`, `uploading` or `failing`), `reason` (failing only), `stuck`. |

`total` comes from Velum's own tracking and can briefly differ from the lid's `files`, which also counts uploads macOS reports before Velum has checked the file.
