# Paradiddle Documentation Index
---

## Documentation Tree

```
docs
│   [README.md](~/paradiddle/docs/README.md)
│   [cli-integration-plan.md](~/paradiddle/docs/cli-integration-plan.md)
│   [feature-extension-ideas.md](~/paradiddle/docs/feature-extension-ideas.md)
│   [video-showcase-plan.md](~/paradiddle/docs/video-showcase-plan.md)
│
└───architecture
│   │   [architecture.md](~/paradiddle/docs/architecture/architecture.md)
│   │   [architecture-enhanced.md](~/paradiddle/docs/architecture/architecture-enhanced.md)
│   │   [command-flags-ux-plan.md](~/paradiddle/docs/architecture/command-flags-ux-plan.md)
│   │   [demo-script.md](~/paradiddle/docs/architecture/demo-script.md)
│   │   [rust-ide-plans.md](~/paradiddle/docs/architecture/rust-ide-plans.md)
│   │   [tiling-window-manager.md](~/paradiddle/docs/architecture/tiling-window-manager.md)
│   │   [workflow-enhancement-plan.md](~/paradiddle/docs/architecture/workflow-enhancement-plan.md)
│
└───implementation
    │   [command-creator-log.md](~/paradiddle/docs/implementation/command-creator-log.md)
    │   [floating-terminal-focus.md](~/paradiddle/docs/implementation/floating-terminal-focus.md)
```

---

## Document Categories

### 📖 Overview
- [README.md](~/paradiddle/docs/README.md) - Main documentation index with quick start guide

### 🏗️ Architecture & Planning
Forward-looking architecture documents and design plans for future development.

| Document                                                                   | Description                                                                          |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| [architecture.md](/architecture/architecture.md)                           | Foundation architecture (v1.0) - Problem statement, system context, component design |
| [architecture-enhanced.md](/architecture/architecture-enhanced.md)         | Enhanced architecture (v2.0) - VS Code patterns, Cursor AI integration               |
| [tiling-window-manager.md](/architecture/tiling-window-manager.md)         | Vision for integrated tiling WM with i3/sway-inspired layouts                        |
| [rust-ide-plans.md](/architecture/rust-ide-plans.md)                       | Architecture context summarizing the three-tier architecture plan                    |
| [workflow-enhancement-plan.md](/architecture/workflow-enhancement-plan.md) | Workflow improvements - smart suggestions, keyboard shortcuts                        |
| [command-flags-ux-plan.md](/architecture/command-flags-ux-plan.md)         | Two-stage command builder UX - hierarchical command search with interactive flags    |
| [demo-script.md](/architecture/demo-script.md)                             | Demonstration scenarios showing the IDE in action                                    |

### ⚙️ Implementation Guides
Technical documentation for features currently implemented in Paradiddle.

| Document                                                                 | Description                                                                                 |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| [floating-terminal-focus.md](/implementation/floating-terminal-focus.md) | Smart terminal switching system - manages stacked floating terminals with intelligent focus |
| [command-creator-log.md](/implementation/command-creator-log.md)         | Development log tracking command search system, tmux scrolling fixes, keybinding evolution  |
|                                                                          |                                                                                             |

### 🎯 Planning
Quick notes and planning documents.

| Document                                                  | Description                                            |
| --------------------------------------------------------- | ------------------------------------------------------ |
| [cli-integration-plan.md](/cli-integration-plan.md)       | Plan for integrating additional CLI tools into the IDE |
| [video-showcase-plan.md](/video-showcase-plan.md)         | Plan for creating demonstration videos of IDE features |
| [feature-extension-ideas.md](/feature-extension-ideas.md) | Quick notes and feature ideas for future development   |
|                                                           |                                                        |

---

## Quick Links

### Related Project Files
- [Main README](./README.md) - User-facing project README
- [CLAUDE.md](./CLAUDE.md) - Instructions for Claude Code AI assistant

### Key Topics
- **Terminal Management**: [Floating Terminal Focus](/implementation/floating-terminal-focus.md)
- **Command Search**: [Command Creator Log](/implementation/command-creator-log.md)
- **Architecture Plans**: [Rust IDE Plans](/architecture/rust-ide-plans.md)
- **Tiling WM Vision**: [Tiling Window Manager](/architecture/tiling-window-manager.md)

---

## Current Implementation Status

**Paradiddle v2.5** (NvChad-based)
- ✅ 8 integrated CLI tool terminals with left-hand keybindings
- ✅ 6 fuzzy command search terminals
- ✅ Smart terminal focus management with stacking
- ✅ Auto-start behavior for all tools
- ✅ Shortcuts cheatsheet (ALT+Shift+?)
- ✅ Catppuccin Mocha theme throughout

**Terminal Keybindings:**
- Home Row: ALT+a/s/d/f/g (Claude, Tmux, Lazydocker, Lazygit, k9s)
- Top Row: ALT+e/r (e1s, Posting)
- Bottom Row: ALT+x/z (OpenAI, Kill)
- Command Search: ALT+q, ALT+Shift+G/D/A/X/B

