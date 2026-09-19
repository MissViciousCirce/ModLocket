# Online comparison preview 04 validation

199 passed, 0 failed on PowerShell 7.6.6/Linux, including 23 new cases.
Twelve native Windows process/interruption tests skipped; expected Windows
suite total is 211. All PowerShell files parsed as part of the suite.

New tests cover read-only local comparison without a backup, missing library
and folders, changed IDs, tiny lists without payloads, preservation of existing
snapshots and pointers, absent remembered mods, stale approval, malformed and
duplicate identities, integer precision, corrupt lists, interrupted publication,
ARK/account ambiguity, empty sets, matched/different/omitted published IDs,
wrong-game/duplicate API results, failed batches, 101-ID batching, concurrent
local changes, fixed HTTPS endpoint/redirect policy and sanitized HTTP errors.

All network calls are mocked. No approved key was available. These passes do
not prove CurseForge exposes this game's projects to a given key, or that its
main-file ID is suitable for the user's platform/server. Published differences
are review findings, not automatic update or install instructions.

The API helper uses the documented POST /v1/mods endpoint and x-api-key header:
https://docs.curseforge.com/rest-api/

Full snapshot and worker modules remain byte-identical to UI03. Core changes
route two comparison/list actions and load their new module; existing launch,
copy, restore and deletion logic is retained. Approved artwork is unchanged.
No payload deduplication or automatic mod downloading is implemented.

Windows Forms rendering, DPI, native encrypted credential storage, and actual
live API integration remain unverified. Check-Interface.cmd provides a sample
UI construction check without reading real mod records or making HTTP calls.

A small list is not an offline recovery copy and cannot authorize the existing
protected launch. Saving one never deletes or supersedes a full snapshot.
