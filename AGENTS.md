# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Build & Test Commands

This project uses XcodeGen to generate the Xcode project from `project.yml`. Always regenerate after changing the project configuration or adding/removing source files.

```bash
# Regenerate Xcode project (required after adding/removing files)
xcodegen generate

# Build
xcodebuild build -project AgentSkillManager.xcodeproj -scheme AgentSkillManager -destination 'platform=macOS'

# Run all tests (109 tests across 8 suites)
xcodebuild test -project AgentSkillManager.xcodeproj -scheme AgentSkillManager -destination 'platform=macOS'

# Run a single test suite
xcodebuild test -project AgentSkillManager.xcodeproj -scheme AgentSkillManager -destination 'platform=macOS' -only-testing:AgentSkillManagerTests/SkillParserTests

# Run a single test
xcodebuild test -project AgentSkillManager.xcodeproj -scheme AgentSkillManager -destination 'platform=macOS' -only-testing:AgentSkillManagerTests/SkillParserTests/testParseValidFrontmatter
```

Note: The test target is `AgentSkillManagerTests` but runs under the `AgentSkillManager` scheme (no separate test scheme).

## Architecture

Three-layer architecture with unidirectional data flow:

```
Views → AppViewModel → { Claude SkillManager, Codex SkillManager }
                             ↕                    ↕
            { FileSystemManager, GitManager, SkillParser, MetadataStore, CodexConfigStore }
```

- **Models** (`Sources/Models/`): `Skill` (core data type) and `SkillMetadata` (Codable struct for metadata.json entries). All `Sendable`.
- **Services** (`Sources/Services/`): Business logic layer. `SkillManager` is the main orchestrator (`@MainActor @Observable`) for one provider, coordinating `FileSystemManager` (directory scanning, copy/move/delete, symlink ops), `GitManager` (git clone/pull via `Process`), `SkillParser` (YAML frontmatter extraction), `MetadataStore` (JSON persistence), and `CodexConfigStore` (Codex enable/disable overrides in `~/.codex/config.toml`).
- **ViewModels** (`Sources/ViewModels/`): Single `AppViewModel` (`@MainActor @Observable`) wrapping both provider-specific managers, adding UI-specific state (provider switching, search, selection, editor, sheet/alert flags).
- **Views** (`Sources/Views/`): SwiftUI views using `NavigationSplitView`. `ContentView` is the root container; `SidebarView`, `DetailPanelView`, `EditorView`, `AddSkillView` are composed within it.

## Key Conventions

- **Swift 6 strict concurrency** — `SWIFT_STRICT_CONCURRENCY: complete` in project.yml. All models are `Sendable`. `SkillManager` and `AppViewModel` are `@MainActor`.
- **Swift Testing framework** — Tests use `import Testing` with `@Suite`, `@Test`, `#expect`, `#require` (not XCTest). Use `@testable import AgentSkillManager`.
- **No external dependencies** — YAML parsing is hand-written. Git operations shell out via `Process`. No SPM packages, CocoaPods, or frameworks beyond Foundation and SwiftUI.
- **macOS 14+ (Sonoma)** — Uses `@Observable` (Observation framework), `NavigationSplitView`, and other macOS 14+ APIs.
- **Module name** — `PRODUCT_MODULE_NAME: AgentSkillManager` (explicit because the product name "Agent Skill Manager" has spaces).

## File System Paths

The app manages skills across these directories:

| Path | Purpose |
|------|---------|
| `~/.claude/skills/` | Active Claude Code skills |
| `~/.claude/skills-disabled/` | Disabled Claude Code skills |
| `~/.agents/skills/` | Personal Codex skills |
| `~/.codex/config.toml` | Codex skill enable/disable overrides via `[[skills.config]]` |
| `~/Library/Application Support/Agent-Skill-Manager/repos/` | Cloned Git repos for URL-installed skills |
| `~/Library/Application Support/Agent-Skill-Manager/metadata.json` | Claude install metadata (source URLs, timestamps) |
| `~/Library/Application Support/Agent-Skill-Manager/codex-metadata.json` | Codex install metadata (source URLs, timestamps) |

## Requirements

Full requirements document at `docs/reqdocs/requirements.md` covering FR-1 through FR-9 (functional) and NFR-1 through NFR-4 (non-functional). Build progress and deferred SHOULD-FIX items tracked in `docs/progress/build-progress.md`.
