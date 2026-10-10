# No BattlEye and updater patch - 2026-10-10

Validated on Windows PowerShell 5.1:

- 211 Windows safety checks passed with NativeCopy, including worker containment
  and native Robocopy cancellation.

- 26 updater fixture tests passed, including premium/current classification,
  freemium access, stale project summaries, newer installed versions, timezone
  offsets, expired plans, installation, rollback and interrupted recovery.
- 24 recovery/Launch anyway fixture tests passed.
- NoBattlEye.Tests.ps1 passed: both protected GUI launch paths request
  `steam://launch/2399830/option1`; cancellation, active close prompts, invalid
  or stale approvals, and launch failures remain blocked. Steam was mocked.
- Personal.Tests.ps1 passed: syntax, encrypted key save/reload/replacement,
  automatic reuse, and destination-space checks.
- Live AutoDoors Windows file 8441790 downloaded through the app downloader
  (459,973 bytes) and passed the published checksums. No ARK files were changed.

Live CurseForge metadata confirmed Sci-Fi Soldier Windows file 7641254 is the
current release and AnimeGirlCosmetics installed file 6571379 is a beta newer
than stable file 5205835. AnimeGirlCosmetics disables third-party distribution;
its official download URL request was denied. This is not evidence that the
API key is generally invalid.

Actual ARK startup without BattlEye and live update installation were not tested.
The earlier intermittent saved-key error in a separately launched desktop
process was not conclusively resolved; isolated key reuse tests passed.

# Earlier Build 09 validation - 2026-10-02

242 automated checks passed on PowerShell 7.4.13/Linux:

- 24 missing-mod recovery and Launch anyway checks.
- 19 existing updater checks.
- 199 existing backup, catalog, launch, and management checks.

Twelve Windows kernel/process tests were skipped. Windows Forms appearance,
Windows PowerShell 5.1 execution, and restoration into a running ARK installation
have not been verified. This is a personal test build, not a verified release.

The new checks restore whole folders and missing installation records from
real synthetic snapshots; exercise an empty installed-mod array and a missing
Mods directory; preserve newer versions, new mods, enabled preferences and
large integer account identifiers; retain OutOfDate and Pending states; reject
conflicting content, damaged backups, stale approvals, malformed records and
links; and recover interruptions during copying and before the atomic metadata
commit. Concurrent external metadata changes stop replay without overwriting.

Launch anyway tests invoke the actual callback with a mocked Steam launch.
They verify that outdated/pending entries do not block it, a backup/API key is
not required, mod payload and metadata hashes do not change, and active or
unfinished writes still prevent launch.

Recovery is additive: selected payloads are copied without overwrites, then
missing records are inserted into the current JSON with exact source spans.
Existing records and unrelated JSON fields are not reserialized. Exact before
and after metadata copies and a journal are retained under RestoreTransactions.
Interrupted recovery resumes from verified files; it does not reset externally
modified records. A complete missing or malformed library.json is not guessed.

Tests make no real CurseForge requests or Steam launches. Passing does not
establish that ARK will load an old mod or that a server will accept its version.
