# Agent Skill Manager — Requirements Document

## Overview

Agent Skill Manager is a native macOS desktop application for managing Claude Code and personal Codex skills. It provides a graphical interface to view, add, edit, enable/disable, and delete skills installed in each ecosystem's user-level locations. The app replaces manual file system operations with a cohesive UI, making skill management accessible without terminal commands.

**Target user:** Claude Code and Codex power users who install and customize skills regularly.

**Tech stack:** Swift + SwiftUI, built with XcodeGen (`project.yml`).

**App type:** Standard macOS dock application, follows system appearance (light/dark mode), no custom branding.

## User Stories

### Viewing Skills

- As a user, I want to switch the sidebar between Claude Code and Codex skills so I can quickly browse what I have in each ecosystem.
- As a user, I want to select a skill and see its metadata (name, description, file path, whether it's a symlink, enabled/disabled status) in a detail panel so I can understand what each skill does and where it lives.
- As a user, I want to search/filter my skills by name or description so I can find a specific skill quickly.

### Adding Skills

- As a user, I want to import a skill from a local file or folder so I can install skills I've downloaded or received.
- As a user, I want to install a skill from a public Git repository URL so I can grab skills shared by the community.

### Editing Skills

- As a user, I want to edit a skill's SKILL.md file in a built-in editor so I can customize skill behavior without leaving the app.

### Enabling/Disabling Skills

- As a user, I want to toggle a skill on or off without deleting it so I can temporarily deactivate skills I don't need right now.

### Deleting Skills

- As a user, I want to delete a skill I no longer need, with appropriate confirmation and handling for symlinked vs. directly-installed skills.

### Updating Skills

- As a user, I want to manually pull the latest version of a URL-installed skill so I can get upstream improvements when I choose to.

## Functional Requirements

### FR-1: Skill Discovery & Loading

1. On launch and on every app-focus event (`.onReceive(NotificationCenter...scenePhase)`), the app scans the selected provider's user-level skill locations.
2. For Claude Code, each subdirectory containing a `SKILL.md` file under `~/.claude/skills/` is treated as a skill.
3. The app also scans `~/.claude/skills-disabled/` to discover disabled Claude Code skills.
4. For Codex, each direct child directory containing a `SKILL.md` file under `~/.agents/skills/` is treated as a personal skill.
5. For each skill, the app parses the SKILL.md YAML frontmatter to extract:
   - `name` (string, required)
   - `description` (string, required)
6. The app detects whether the skill directory is a symlink (using `FileManager` symlink APIs).
7. For symlinked skills, the app resolves and stores the symlink target path.

### FR-2: Sidebar

1. The left sidebar displays a segmented provider switcher (`Claude Code`, `Codex`) above a scrollable list of the selected provider's discovered skills.
2. Each entry shows:
   - Skill name (from frontmatter)
   - Truncated description (first ~80 characters, single line)
3. A search bar at the top of the sidebar filters skills by name or description (case-insensitive substring match).
4. Disabled skills are visually distinguished (e.g., dimmed text, a subtle badge, or strikethrough).
5. Selecting a skill in the sidebar populates the detail panel.

### FR-3: Detail Panel

1. The right panel displays metadata for the selected skill:
   - **Name** — from SKILL.md frontmatter
   - **Description** — full description from frontmatter
   - **Provider** — Claude Code or Codex
   - **File path** — absolute path to the selected provider's skill directory
   - **Symlink status** — "Symlink → {target path}" or "Local copy"
   - **Source** — "Imported from file" or "Cloned from {repo URL}" (if metadata available)
   - **Status** — Enabled / Disabled
2. Action buttons in the detail panel:
   - **Edit** — opens the built-in editor for this skill's SKILL.md
   - **Enable/Disable toggle** — switches the skill's active state
   - **Pull Latest** — visible only for URL-installed skills; triggers a `git pull` on the cloned repo
   - **Delete** — removes the skill (with confirmation)

### FR-4: Add Skill — Import from File/Folder

1. User clicks an "Add Skill" button (e.g., toolbar button or `+` in the sidebar).
2. An import option presents an `NSOpenPanel` (macOS native file picker).
3. The user selects either:
   - A directory containing a `SKILL.md` file, or
   - A `SKILL.md` file directly (the app uses its parent directory)
4. Validation: the app checks that a valid `SKILL.md` exists with parseable frontmatter (`name` and `description` fields).
5. If valid, the app **copies** the entire skill directory into the active provider's managed directory:
   - Claude Code: `~/.claude/skills/{skill-name}/`
   - Codex: `~/.agents/skills/{skill-name}/`
6. If a skill with the same name already exists, the app shows a confirmation dialog: overwrite or cancel.
7. The sidebar refreshes to show the newly added skill.

### FR-5: Add Skill — Install from URL

1. User clicks "Add Skill" and selects the URL/repo option.
2. A text field accepts a public Git repository URL (HTTPS).
3. The app clones the repository into `~/Library/Application Support/Agent-Skill-Manager/repos/{repo-name}/`.
4. The app scans the cloned repo for directories containing `SKILL.md` files.
5. If exactly one skill is found, it proceeds automatically. If multiple skills are found, the user selects which one(s) to install.
6. For each selected skill, the app creates a **symlink** in the active provider's managed directory pointing to the skill directory inside the cloned repo.
7. The app stores metadata associating the installed skill with its source repo URL (for the "Pull Latest" feature) in a provider-specific metadata file.
8. The sidebar refreshes to show the newly added skill(s).
9. Errors (invalid URL, clone failure, no SKILL.md found) are shown as alert dialogs with descriptive messages.

### FR-6: Edit Skill

1. Clicking "Edit" on a skill opens a full-panel or sheet editor view.
2. The editor uses SwiftUI's `TextEditor` with a monospace font (e.g., SF Mono or Menlo).
3. The editor loads the full contents of the skill's `SKILL.md` file.
4. A "Save" button writes changes back to disk.
5. A "Cancel" button discards changes and returns to the detail view.
6. If the file has been modified externally since it was loaded, the app warns the user before overwriting.
7. For symlinked skills, editing modifies the file at the symlink target (i.e., the actual source file).

### FR-7: Enable/Disable Skill

1. Each skill has an enable/disable toggle (or button) in the detail panel.
2. **Disabling** a skill:
   - Claude Code: moves the skill directory from `~/.claude/skills/{name}/` to `~/.claude/skills-disabled/{name}/`.
   - Codex: writes a matching `[[skills.config]]` entry to `~/.codex/config.toml` with `enabled = false`.
3. **Enabling** a skill:
   - Claude Code: moves the skill directory from `~/.claude/skills-disabled/{name}/` back to `~/.claude/skills/{name}/`.
   - Codex: removes the matching `[[skills.config]]` override from `~/.codex/config.toml`.
4. The sidebar updates the skill's visual state immediately.
5. If a naming conflict exists in the target directory, the app shows an error and does not proceed.

### FR-8: Delete Skill

1. Clicking "Delete" shows a confirmation alert.
2. **For directly-copied skills (not symlinks):**
   - Confirmation message: "Delete {name}? This will permanently remove the skill and its files."
   - On confirm: deletes the skill directory from `~/.claude/skills/` (or `~/.claude/skills-disabled/`).
3. **For symlinked skills:**
   - Confirmation offers two options:
     - "Remove link only" — deletes just the symlink, leaves the source intact.
     - "Remove link and source" — deletes the symlink AND the source directory it points to.
     - "Cancel" — abort.
   - For URL-installed skills, "Remove link and source" also deletes the cloned repo from `~/Library/Application Support/Agent-Skill-Manager/repos/` and removes the metadata entry.
4. After deletion, the sidebar refreshes and selects the next skill in the list (or shows an empty state).

### FR-9: Pull Latest (Manual Update)

1. The "Pull Latest" button is visible only for skills installed from a URL (identified by metadata).
2. Clicking it runs `git pull` on the associated cloned repo directory.
3. While pulling, the button shows a progress indicator (spinner).
4. On success: the app re-reads the SKILL.md and refreshes the detail panel. A brief success message is shown.
5. On failure (network error, merge conflict, etc.): an alert shows the error output.

## Non-Functional Requirements

### NFR-1: Performance

- Skill directory scanning should complete in under 500ms for up to 100 installed skills.
- The app should feel responsive — no blocking the main thread during Git clone/pull operations. Use Swift concurrency (`async`/`await` with `Task`) for all I/O.

### NFR-2: Error Handling

- All file system operations must handle errors gracefully (permissions, missing directories, corrupt SKILL.md files).
- Skills with unparseable SKILL.md files should still appear in the sidebar with a warning indicator, using the directory name as the display name.
- Git operations (clone, pull) must have timeouts and user-facing error messages.

### NFR-3: Data Safety

- The app never modifies files outside of `~/.claude/skills/`, `~/.claude/skills-disabled/`, `~/.agents/skills/`, `~/.codex/config.toml`, and `~/Library/Application Support/Agent-Skill-Manager/` — except when the user explicitly chooses "Remove link and source" for a symlinked skill.
- All destructive operations (delete, overwrite) require user confirmation.
- The editor warns before overwriting externally-modified files.

### NFR-4: macOS Integration

- Follows system appearance (light/dark mode) automatically via SwiftUI defaults.
- Uses standard macOS UI patterns: `NavigationSplitView` for sidebar/detail, `NSOpenPanel` for file picking, native alert dialogs.
- Minimum deployment target: macOS 14 (Sonoma) — allows use of latest SwiftUI APIs.

## Data Model

### Skill (in-memory model)

| Field | Type | Description |
|-------|------|-------------|
| `id` | `UUID` | Unique identifier (generated at load time) |
| `provider` | `SkillProvider` | Claude Code or Codex |
| `name` | `String` | From SKILL.md frontmatter |
| `description` | `String` | From SKILL.md frontmatter |
| `directoryURL` | `URL` | Path to skill directory in the active provider's storage |
| `isSymlink` | `Bool` | Whether the directory is a symlink |
| `symlinkTarget` | `URL?` | Resolved target if symlink |
| `isEnabled` | `Bool` | true if enabled for the provider, false if disabled via folder move or Codex config override |
| `sourceRepoURL` | `String?` | Git repo URL if installed from URL |
| `rawContent` | `String` | Full SKILL.md file content (loaded on demand) |

### Metadata Store (`metadata.json`)

```json
{
  "skills": {
    "skill-name": {
      "sourceRepoURL": "https://github.com/user/repo",
      "clonedRepoPath": "/Users/.../Application Support/Agent-Skill-Manager/repos/repo",
      "installedAt": "2026-03-02T12:00:00Z"
    }
  }
}
```

Stored at provider-specific paths:
- Claude Code: `~/Library/Application Support/Agent-Skill-Manager/metadata.json`
- Codex: `~/Library/Application Support/Agent-Skill-Manager/codex-metadata.json`

## UI Layout

```
┌──────────────────────────────────────────────────────────────────┐
│  Agent Skill Manager                                    [+ Add]     │
├──────────────────┬───────────────────────────────────────────────┤
│ [🔍 Search...  ] │                                               │
│                  │  Skill Name                                   │
│  skill-one       │  ─────────────────────────────────────────    │
│  Description...  │                                               │
│                  │  Description:  Full description text here     │
│ ▸ skill-two      │  Path:         ~/.claude/skills/skill-one/    │
│   Description... │  Type:         Local copy                     │
│                  │  Status:       ● Enabled                      │
│  skill-three     │                                               │
│  Description...  │  ┌─────────┐ ┌──────────┐ ┌────────┐         │
│                  │  │  Edit   │ │ Disable  │ │ Delete │         │
│  skill-four      │  └─────────┘ └──────────┘ └────────┘         │
│  Description...  │                                               │
│                  │                                               │
│                  │                                               │
└──────────────────┴───────────────────────────────────────────────┘
```

### Editor View (replaces detail panel or opens as sheet)

```
┌──────────────────────────────────────────────────────────────────┐
│  Editing: skill-one/SKILL.md                [Cancel]  [Save]     │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ---                                                             │
│  name: skill-one                                                 │
│  description: >                                                  │
│    A skill that does something useful                            │
│  ---                                                             │
│                                                                  │
│  # Skill Instructions                                            │
│                                                                  │
│  You are a specialized agent that...                             │
│                                                                  │
│                                                                  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## Technical Notes

### Project Structure (XcodeGen)

- Project managed via `project.yml` for XcodeGen.
- Standard SwiftUI app target, no frameworks or packages required for MVP.
- Git operations executed via `Process` (shelling out to `git` CLI) rather than a Git library — keeps dependencies minimal and leverages the user's existing Git installation.

### SKILL.md Parsing

- YAML frontmatter is delimited by `---` markers at the top of the file.
- Parse the frontmatter to extract `name` and `description`. A lightweight approach: split on `---`, parse the YAML block manually or use a small YAML parsing utility.
- The rest of the file after the closing `---` is the instruction body (not parsed, just stored as raw text).

### File System Paths

| Path | Purpose |
|------|---------|
| `~/.claude/skills/` | Active Claude Code skills |
| `~/.claude/skills-disabled/` | Disabled Claude Code skills |
| `~/.agents/skills/` | Personal Codex skills |
| `~/.codex/config.toml` | Codex enable/disable overrides |
| `~/Library/Application Support/Agent-Skill-Manager/repos/` | Cloned Git repos for URL-installed skills |
| `~/Library/Application Support/Agent-Skill-Manager/metadata.json` | Claude install metadata |
| `~/Library/Application Support/Agent-Skill-Manager/codex-metadata.json` | Codex install metadata |

### Concurrency Model

- All file I/O and Git operations run off the main thread using Swift concurrency (`async`/`await`).
- UI state is managed via `@Observable` classes (macOS 14+ Observation framework) or `ObservableObject` with `@Published`.
- Git clone/pull operations use `Process` wrapped in an async helper.

## Open Questions

_None — all requirements were resolved during the interview._

## Out of Scope

- **Skill creation from scratch** — users create skills externally and import them.
- **Skill registry / marketplace** — no browsing of a centralized skill catalog.
- **Private repository support** — only public HTTPS Git URLs are supported.
- **Syntax highlighting in editor** — the editor is a basic monospace TextEditor.
- **Automatic update checking** — users manually trigger pulls for URL-installed skills.
- **Cross-platform support** — macOS only.
- **Menu bar mode** — standard dock app only.
