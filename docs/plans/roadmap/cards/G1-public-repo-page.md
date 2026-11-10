# G1 · The public repo page

**Bucket** G Going public · **Part two** · **Status: planned; your decisions** · **Waits for** the app icon (on hold), R2, S2 · **Runs alongside** S1, G2, R3 · **Feeds** G3, R3

## Brief

The repo is private until the app icon is settled; the icon is on hold at your word. When it goes public, the page is most people's first and only look at Velum. The consultant's guidance:
- **Name and taglines** ([memo](../strategy-memo.md) §4). Keep the name. Use "Every OneDrive account, one cloud in your menu bar." now, and "Every cloud, one icon. Know your files are synced." after iCloud. Keep "merge, don't hide".
- **Lead with the pain.** Public copy should open with the OneDrive multi-account problem people already complain about in MacRumors, Microsoft Q&A and Parallels threads [S].
- **Page contents** (§5, item 6): a screenshot, a 20-second GIF, and issue templates asking for redacted `--dump` output (S2's report).
- **Funding** (§5, item 8): free forever, with sponsors covering Apple's fee, as Crisp frames it [V].

**Privacy before public.**
- Velum's real panel shows your account names, your organization and your recent files. Screenshots and the GIF must use made-up data, through a demo mode (earlier screenshots used made-up names, which you agreed to).
- The history must be checked before the switch: commits use the noreply address, but check every file in every commit.

Read the [campaign rules](../README.md#rules-every-card-follows), the README, `.gitignore`, and Crisp's `.github/ISSUE_TEMPLATE/` and `FUNDING.yml`.

**The idea:** a shop window. One glance says what it is and who it's for, and nothing behind the glass belongs to the shopkeeper's private life.

## Work

- **A demo mode:** `Velum --demo` draws the panel from made-up accounts, files and states, for screenshots. It is never on by default.
- **The README rewritten for strangers:**
  - the tagline;
  - the problem in one short paragraph;
  - the screenshot;
  - "What you get";
  - install from the DMG and from Homebrew (R3);
  - "How Velum knows" (keep it: it's the trust story);
  - the network sentence, as decided in R2;
  - a FAQ on permissions;
  - Credits and License.
- **Images** under `docs/`. The GIF is recorded with the user: Screen Recording permission is theirs.
- **`.github/ISSUE_TEMPLATE/`:** a bug report asking for macOS, Velum and client versions plus S2's redacted report; a provider request that points to G2's guide. Plus a pull request template.
- **`.github/FUNDING.yml`,** as you decide.
- **A scrub report before the switch.** Search every commit of every file for your Gmail address, account and organization names, absolute home paths and real file names. Fix anything found. History is rewritten only with your explicit yes.
- **The switch to public is yours:** you click it, or say so in words.

## Done when

- The README renders on GitHub with its images.
- The templates work: try a draft issue in the private repo, then delete it.
- The scrub report is clean.
- You have made the repo public.

## Ownership and limits

You own:
- `README.md`;
- images under `docs/`;
- `.github/ISSUE_TEMPLATE/` and the pull request template;
- `.github/FUNDING.yml`;
- the `--demo` flag (a new file, plus one line in `Entry.swift`).

## Decisions for the user

| Decision | Suggested |
|---|---|
| The app icon | On hold, your call; this card waits for it |
| When the repo goes public | After R2's first release and the icon |
| Whether `docs/plans/` goes public with it | Yes: it shows where Velum is going; check it in the scrub |
| Sponsor links | GitHub Sponsors only |

## Hand-off

_Not started._
