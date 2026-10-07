# Project context — DustPan

**Type:** macOS app plus separate Desktop organisation workflow
**Purpose:** Help the user review and organise files while preserving privacy and recoverability. The user confirmed that both strands belong in this project.

## Native macOS app

- `DustPan.xcodeproj` — primary project and shared `DustPan` Run scheme for Xcode.
- `Sources/DustPan/DustPanApp.swift` — SwiftUI two-pane Desktop sorter.
- `AppAssets.xcassets/AppIcon.appiconset` — macOS app icon at standard sizes; `AppResources/AppIcon.svg` is the editable vector master.
- `Package.swift` — secondary Swift Package command-line build route.

The app presents visible, non-sensitive-named regular files and ordinary Desktop folders in a searchable multi-select list. The four core destination folders and the review/cleanup folders stay out of the source list; hidden, symbolic-link, and access-sensitive names are omitted. The right pane browses existing University, Career, Personal, and Work folders, with a pinned Bin action that remains visible while browsing. A single click files the selection, double-click browses into a folder, and the inline rename editor offers Rename/Cancel buttons while preserving file extensions. Destination collisions and symbolic-link paths are rejected. Successful moves and renames are logged; Undo checks that the moved file is still the same file before restoring it. The app does not classify file contents or run the scheduled workflow.

Items can also be hidden from DustPan without changing their Finder visibility or moving them. The app stores hidden paths in its own preferences; the toolbar's Hidden list can show individual items again, and “Unhide all” restores only items directly inside the currently selected source folder. Hiding/unhiding changes app preferences only and does not append a Desktop organisation log entry because no Desktop file is changed.

## Desktop organisation workflow

- The live `daily-desktop-organisation` automation is managed in Codex; inspect its current configuration before relying on its schedule or prompt.
- `Desktop Organisation Log.md` on the user's Desktop records actual runs; dated entries are historical evidence.

The workflow operates on the user's Desktop and existing folder taxonomy. It is a separate automation, not a feature proven to run inside the app. Check the current task request and current automation state before operating it.

Keep accepted decisions in their established source. Add new context here only when it changes how someone should understand or operate this project.
