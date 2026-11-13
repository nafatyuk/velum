# S2 · Diagnostics export, redacted

**Bucket** S Support · **Part two** · **Status: planned** · **Waits for** C2 · **Runs alongside** P1, C3, T1, A5, A6 · **Feeds** G1

## Brief

When Velum shows the wrong thing on someone else's Mac, the only way to fix it is to see what Velum saw. The obvious report is `Velum --dump`, but it is full of personal detail:
- account names and email addresses;
- organization names;
- folder paths with the user's name in them;
- file names.

The consultant's ninth idea is a diagnostics export with automatic redaction ([memo](../strategy-memo.md) §3, idea 9). G1's issue templates will ask for exactly this report (§5, item 6).

Read the [campaign rules](../README.md#rules-every-card-follows), [C2's hand-off](C2-sync-provider-protocol.md#hand-off), `DebugDump` in `Entry.swift`, and A7's compatibility check, if it has landed.

**The idea:** a medical chart with the patient's name blacked out. The doctor still sees every reading.

## Work

- **`Diagnostics.swift` builds the report.** It holds:
  - Velum's version, macOS's version, and each client's version;
  - A7's checks;
  - for each account: provider, kind, state, source, age, counts and coverage gaps;
  - transfers;
  - the tracker's numbers;
  - recent failure reasons;
  - settings toggles.
- **Redaction:**

  | Replaced | With |
  |---|---|
  | Account names and emails | "Account 1", "Account 2" |
  | Organization names | `<org>` |
  | The home folder | `~` |
  | Folder paths under a root | `<root>/…` |
  | File names | `file-1.docx` (the extension is kept, because it often matters) |
  | Text inside failure reasons | The same replacements |

  Replacements stay consistent within one report.
- **Two ways in:**
  - `Velum --dump --redact`;
  - the ••• menu's "Export Diagnostics…", which writes a `.txt` file and shows it in Finder so the user can read it before attaching it anywhere.

  Velum never sends it anywhere.

## Done when

- **A redaction test corpus:** made-up accounts, emails, organizations, paths and file names (including Unicode, spaces, and names that are also ordinary words) go in, and none survives.
- **Live on this Mac:** an exported report, checked by a script that takes the strings to look for from the live configuration at run time, shows none of the user's account names, emails, organization names or file names. The script never writes those strings to the repo or a log.

## Ownership and limits

You own:
- `Diagnostics.swift`;
- the `--redact` flag in `Entry.swift`;
- one ••• menu line in `PanelView.swift`.

No uploads, and no "send to developer" button.

## Hand-off

_Not started._

### What changed since this card was written (November 12)

- **More to redact:**
  - Google Drive account names are email addresses, and they appear in folder names (`GoogleDrive-<email>`);
  - DriveFS folders are named by a numeric Google account ID;
  - storage figures are personal.

  The redaction corpus needs all three.
- **More to report:** per service, the evidence each row used (OneDrive's report, iCloud's `brctl`, Google Drive's queue and pause), and where storage came from (Drive's cache or the optional sign-in). Never include the sign-in's tokens.
- **A debug log exists now (November 12, the owner's request).** ••• → Debug Logging writes status changes, alerts, gaps and failures to `~/Library/Logs/Velum/Velum.log` (`Sources/Velum/DebugLog.swift`, 2 MB rotation). S2's export should include its recent lines, redacted like the rest, since that's where "what happened an hour ago" lives.
