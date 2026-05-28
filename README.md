# ObsidianReminders

ObsidianReminders is a macOS app that syncs Obsidian tasks with Apple Reminders. It is designed for daily notes and selected task files, including workflows built around the Obsidian Tasks plugin.

## Download

Download the packaged app here:

[ObsidianReminders.zip](./ObsidianReminders.zip)

This build is ad-hoc signed and not notarized with Apple. macOS will ask you to explicitly trust it the first time you open it.

## Install

1. Download and unzip [ObsidianReminders.zip](./ObsidianReminders.zip).
2. Move `ObsidianReminders.app` to `/Applications`.
3. Control-click the app and choose **Open**.
4. If macOS blocks it, open **System Settings > Privacy & Security** and choose **Open Anyway**.
5. Grant Reminders access when the app asks.

## Use

1. Choose your Daily Notes folder.
2. Add any standalone Markdown task files, such as `Todo.md`.
3. Set the default Reminders list, and optionally set separate lists for Daily Notes or individual task files.
4. Press **Apply Lists** after editing list names.
5. Press **Sync**, or leave **Auto** enabled for background sync.

## Features

- Syncs unchecked and checked Obsidian tasks to Apple Reminders.
- Pulls completed Reminders back into Obsidian as checked tasks.
- Syncs renamed tasks in both directions.
- Supports Daily Notes and multiple additional task files.
- Supports per-source Reminders lists.
- Can skip old Daily Notes tasks and clear their Reminders.
- Preserves Reminders-side deletions as excluded tasks.
- Lets you remove stale rows from the app view without tombstoning them.

## Build From Source

Open `ObsidianReminders.xcodeproj` in Xcode and build the `ObsidianReminders` scheme.

For a shareable unsigned build, use the `CommunityRelease` configuration:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project ObsidianReminders.xcodeproj \
  -scheme ObsidianReminders \
  -configuration CommunityRelease \
  -derivedDataPath build-community \
  clean build
```

Then zip the app:

```bash
cd build-community/Build/Products/CommunityRelease
zip -r -X ../../../../ObsidianReminders.zip ObsidianReminders.app
```

