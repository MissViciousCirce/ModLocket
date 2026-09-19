MODLOCKET FOR ASA - By ViciousCirce
ONLINE COMPARISON 04 | PRIVATE CONNECTION PREVIEW

START
Close ARK and other ModLocket windows. Extract into a new folder and run
Start-ModLocket.cmd. Existing full backups are reused; do not recreate them.

CHECK FOR UPDATES
Now compares local recorded file IDs, the selected full backup, an optional
small saved mod list, and published CurseForge main-file IDs. ARK does not need
to run first. Without approved API access, only the local comparison works.
The dark connection dialog accepts an optional approved CurseForge API key.
Leaving it blank keeps a previously stored key. API access information:
https://docs.curseforge.com/rest-api/#getting-started
No key is bundled. Actual ARK API access has NOT been verified in this preview.
Do not paste your key into a chat or send it with diagnostic reports.

A different published file ID means review the update. It does not establish
platform/server compatibility or ownership. A matching ID is not an integrity
check. Unavailable projects and failed requests remain explicitly unknown.
The checker does not download/install mods or update your server.

SMALL MOD LIST VERSUS FULL BACKUP
Use Check for Updates, then Save mod list only. This saves names, IDs and
recorded file versions without copying mod payloads. It remembers previously
saved missing mods too. It cannot discover mods absent from every known list.
The list requires very little storage and does not require a full backup.
It cannot restore files offline or approve the existing protected launch.

BACKUP still creates a complete independent file copy for offline restoration.
No incremental/deduplicated file storage is implemented. Existing full copies
are never deleted automatically. Manage Backups retains its explicit reviewed
older-copy deletion and current-copy protection. Do not delete a full backup
expecting a small list to replace its recovery capability.
Launch ARK and Restore Missing Files retain their prior full-snapshot checks.

CONNECTION SETTINGS
A key entered in the dialog is encrypted for your Windows account in
LocalAppData/ModLocketSafetyPreview/curseforge-key.txt. Delete that file to
remove it. An optional MODLOCKET_CURSEFORGE_API_KEY environment variable takes
precedence. Online checks run only when you request Check for Updates.
No shared developer credential is embedded. Public distribution requires an
approved access arrangement, not a copied application/game credential.

VALIDATION
199 synthetic portable tests passed, zero failed. No real network request,
API key, mod data, or server was used. Twelve native Windows tests cannot run
on the Linux build host. The new dark dialogs and Windows key encryption need
Windows confirmation; the live service needs approved ARK-capable API access.
Run-Windows-Safety-Tests.cmd uses isolated fixtures, never real mods or HTTP.
Check-Interface.cmd opens sample-only dark dialogs and the existing interface.

The approved logo, original hair, footer snakes, READY SURVIVOR greeting,
progress display and Close Anyway behavior are preserved. Close Anyway remains
only in the close-during-work dialog. Installation/public publishing disabled.
