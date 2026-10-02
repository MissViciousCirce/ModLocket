# 🔒 ModLocket

### A Windows companion for ARK: Survival Ascended that helps keep your mods from disappearing.

ModLocket was created because ARK: Survival Ascended mods can sometimes disappear from the local installation, stop showing up, or otherwise leave you wondering why a cosmetic or mod you were using suddenly isn't available anymore.

ModLocket keeps a record of your mod setup so it can recognize when something that was previously there has gone missing.

> **Early Alpha / Prototype**
>
> ModLocket is currently an early working prototype and my first programming project. Feedback, testing, bug reports, and code review are welcome.

---

## 🦖 What ModLocket Does

### 📸 Snapshot Your Mods

ModLocket can record your current installed mod setup so you have a known-good reference point.

This gives it something to compare against later instead of relying only on whatever ARK currently sees.

### 🔎 Detect Missing Mods

When ModLocket checks your installation, it compares your current mods against the recorded snapshot.

If something that used to be installed is missing, ModLocket can identify it instead of letting it disappear unnoticed.

### 💾 Full Backups

ModLocket can create a complete backup of your mod files.

A full backup can be used to restore missing files without needing to download them again.

Existing backups are preserved and are not silently deleted.

### 📋 Lightweight Mod Lists

If you don't want to create a complete backup, ModLocket can also save a lightweight list containing information such as:

* Mod names
* Project/mod IDs
* Recorded file versions
* Previously known missing mods

This uses very little storage.

**Important:** A lightweight mod list can detect differences, but it cannot restore the actual mod files. For offline restoration, you need a full backup.

### 🚀 Protected ARK Launch

ModLocket can check your recorded mod setup before launching ARK so missing files can be caught before you get into the game and discover something isn't there.

---

## CurseForge downloads - personal build 07

CHECK FOR UPDATES now opens a Windows-client update review with a **Download and install updates** action. It uses the saved API key, verifies archive lengths and hashes, rejects unsafe ZIP paths, verifies the module layout, and retains old versions plus original library metadata for interruption recovery.

After installation, make a fresh backup before protected launch. The installer does not silently replace existing snapshots. Pending/invalid installs, premium content, missing dependencies and unsupported formats require ARK's mod manager. API permission to read metadata does not establish download permission. Server-version matching is not inferred from a newer file ID.

See START-HERE.txt for the launch instructions and limitations. Run Start-ModLocket.cmd in this folder; an older EXE will still run the old code. This build has synthetic test coverage but has not been tested with live ARK or the Windows UI.

Implementation references: [CurseForge REST API](https://docs.curseforge.com/rest-api/), [installed-mod fields and status](https://docs.curseforge.com/docs/game-integration/unreal/installing-mods/), and [CDN API-key headers](https://blog.curseforge.com/introducing-api-key-authentication-for-curseforge-file-downloads/).

---

## 🖥️ Requirements

* Windows
* ARK: Survival Ascended installed
* PowerShell
* Enough free storage if creating full mod backups

This prototype is currently designed for Windows.

---

## 📥 Running the Current Prototype

Until a packaged public release is available:

1. Click **Code → Download ZIP** on this repository.
2. Extract the ZIP into its own folder.
3. Close ARK before running ModLocket.
4. Run:

```text
Start-ModLocket.cmd
```

Keep the ModLocket files together in the extracted folder.

### First use

Create a snapshot or backup while your mod installation is in a state you consider correct.

That becomes ModLocket's reference for detecting missing mods later.

---

## ⚠️ Early Alpha Warning

This is an early prototype.

Although ModLocket is designed to avoid destructive operations, you should treat any early software that manages game files carefully.

If you have anything important, keep your own backup.

If you find something broken, weird, confusing, or unsafe, please report it.

---

## 🐛 Bugs & Feedback

Feedback is extremely welcome, especially from other ARK: Survival Ascended players who have experienced mods randomly disappearing.

If you encounter a bug, please open a GitHub Issue and include:

* What you were trying to do
* What you expected to happen
* What actually happened
* Any error message shown
* Your Windows version
* Whether ARK was running at the time

Please **do not include API keys or other credentials** in bug reports.

---

## 🧪 Development & Testing

ModLocket includes automated and synthetic safety tests for its core behavior.

The project is still under active development, and real-world testing on different ARK installations is especially useful.

Developers are welcome to inspect the source, suggest improvements, or point out questionable architecture. This is my first software project, so constructive criticism is genuinely useful.

---

## 🗺️ Planned Features

Current priorities include:

* CurseForge version/update checking
* Easier installation
* Packaged Windows releases
* Better diagnostics and error reporting
* Continued backup/restore safety improvements
* Feedback-driven improvements from ARK players

The goal is to keep ModLocket focused: **know what mods should be there, notice when they aren't, and make recovery easier.**

---

## 🔐 Privacy

ModLocket is designed to operate primarily on your local computer.

No shared CurseForge developer credential is embedded in the application.

Explicit update checks and downloads use CurseForge API and CDN requests; see PRIVACY.txt.

See `PRIVACY.txt` for additional details.

---

## 📜 License

See `LICENSE.txt` for licensing information.

---

## Disclaimer

ModLocket is an independent community project.

It is not affiliated with, endorsed by, or sponsored by Studio Wildcard, Snail Games, CurseForge, Overwolf, or the ARK: Survival Ascended development team.

ARK: Survival Ascended and related names and trademarks belong to their respective owners.

---

### Created by ViciousCirce

Built because I got tired of opening ARK and discovering that one of my mods had apparently wandered off into the fucking wilderness.
