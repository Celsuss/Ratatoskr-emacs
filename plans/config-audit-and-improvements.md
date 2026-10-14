# Plan — Ratatoskr-emacs Audit & Core Improvements (`plans/config-audit-and-improvements.md`)

Status: **proposed** (written 2026-10-14). Future implementation sessions will execute
this plan phase by phase. No code was implemented during the initial audit session.
Each `## Phase N` below is one self-contained unit of work, designed to be implemented
and verified incrementally.

> [!NOTE]
> All AI agent-specific workflows (Agent Review Mode, Second Brain MCP Bridge,
> Spec-Driven Agent Spawning, Proactive Error Feedback, .ratarules, and Dev-Log Auto-Capture)
> are consolidated in [`plans/ai-agent-powerhouse.md`](ai-agent-powerhouse.md).
> This plan focuses exclusively on Core Emacs Architecture, Completion, Build Tooling,
> Git Conflict Ergonomics, and Org-roam PKM Reading Experience.

**This file is the progress record:** a phase is closed by appending ` [done]` to its
heading, or ` [blocked: <reason>]` when it needs operator intervention. The first heading
with neither marker is the next phase. Nothing is committed autonomously (SAFETY_RULES),
so git history is not the progress record — this file is.

---

## How to run this plan

In interactive Claude Code or Antigravity, in this repo, with one command:

```text
/goal Implement plans/config-audit-and-improvements.md phase by phase, following its "Rules for each phase". Done when `grep -E '^## Phase' plans/config-audit-and-improvements.md | grep -vcE '\[(done|blocked: .*)\]$'` prints 0, every [done] phase has a line under its heading recording passing tests (`just test`), and the last message reports PASS/FAIL/NOT TESTED per area. Stop after 10 tries.
```

### Rules for each phase

1. Re-read the "Design" section and the target phase. Work on the first `## Phase N`
   heading with no `[done]` / `[blocked: ...]` marker, and only that one.
2. Follow `AGENTS.md` guidelines: test pure functions first, run verification commands
   (`just lint`, `just compile`, `just test`), and preserve existing docstrings and
   architectural patterns.
3. Write ERT tests in `tests/run-tests.el` before the implementation code, and see them fail.
   Ensure test runs **NEVER** touch `~/workspace/second-brain/` or private credentials; tests
   must operate exclusively on temporary directories or mock fixtures.
4. Run verification (`just lint && just compile && just test`). Never weaken, skip, or
   delete a test to get it green.
5. When it passes, append ` [done]` to the phase heading and add a one-line record under it:
   date, verification level run, PASS / FAIL / NOT TESTED per area.
6. If the phase needs an operator decision, or verification still fails after two honest
   fix attempts, append ` [blocked: <one-line reason>]` and stop.
7. Never commit autonomously (SAFETY_RULES).

---

## Architectural Context & Audit Findings

Following a deep audit of the configuration across startup sequences, keybindings, module dependencies, Org-roam, and developer tooling, the following findings and opportunities were identified:

```
                       +---------------------------------------+
                       |        Ratatoskr-emacs Core           |
                       +---------------------------------------+
                                           |
      +--------------------+---------------+-------------------+--------------------+
      |                    |                                   |                    |
      v                    v                                   v                    v
+--------------+   +---------------+                   +---------------+    +---------------+
| Architecture |   |  In-Buffer    |                   | Git & Build   |    |  Org-Roam &   |
|   & Paths    |   |  Completion   |                   |  Ergonomics   |    | Second Brain  |
+--------------+   +---------------+                   +---------------+    +---------------+
| * Unify path |   | * Corfu doc   |                   | * Smerge git  |    | * Protocol    |
|   in system  |   |   popups      |                   |   conflicts   |    |   ingestion   |
| * Fix khoj   |   | * Cape back-  |                   | * Fix Magit   |    | * Typography  |
|   hardcoding |   |   ends        |                   |   commit win  |    |   & reading   |
| * Fix httpd  |   | * Dumb-jump   |                   | * Just runner |    |   margins     |
|   recipe     |   |   fallback    |                   |   under SPC   |    |               |
+--------------+   +---------------+                   +---------------+    +---------------+
```

### 1. Architecture & Single Source of Truth
- **Path Fragmentation**: `rata-org-roam-dir` is currently defined in `lisp/init-org.el` (line 8). However, `init-khoj.el` loads *before* `init-org.el` in `init.el` (line 142 vs 153), forcing `init-khoj.el` to hardcode `"~/workspace/second-brain/org-roam/"`. Moving `rata-org-roam-dir` to `init-system.el` establishes a clean, unified source of truth available to all modules.
- **Recipe Mismatch**: `lisp/init-org.el` (line 848) contains an explicit recipe pointing `simple-httpd` to `skeeto/emacs-web-server`. Chris Wellons' repository is `skeeto/emacs-httpd`.

### 2. In-Buffer Completion & Navigation
- **Corfu Documentation Popups**: Corfu is active with `corfu-auto` and `cape`, but `corfu-popupinfo-mode` is disabled. Enabling it adds instant, floating documentation and signature popups alongside completion candidates without UI lag.
- **Navigation Resilience**: When LSP is disconnected, indexing, or unavailable, adding `dumb-jump` as an xref fallback allows instant definition jumping across projects.

### 3. Git Conflicts, Window Cleanup & Build Ergonomics
- **Merge Conflict Resolution**: Git conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`) are handled via built-in `smerge-mode`, but no Evil leader keybindings are configured. Adding standard `SPC g m` keys makes resolving conflicts effortless.
- **Magit Commit Window Cleanup Fix**: When finishing a commit (`C-c C-c`), Magit closes but often leaves an orphaned split window displaying a duplicate or previous buffer. Adding `magit-restore-window-configuration` and a `git-commit-post-finish-hook` cleanup ensures the split window is deleted upon commit completion.
- **Build System Ergonomics**: `lisp/init-just.el` is an 8-line stub. Given that the repository and the user's projects are driven by `justfile`s, providing an interactive `just` recipe selector (`completing-read`) bound to `SPC p j` provides immediate build execution.

### 4. Org-Roam Second Brain Reading & Ingestion
- **Browser & Web Ingestion**: `org-roam-protocol` enables capturing links, highlights, and notes directly from web browsers via bookmarklets (`org-protocol://roam-ref`).
- **Reading Typography**: Optional `mixed-pitch-mode` and centered reading margins (`visual-fill-column-mode` / `olivetti`) for distraction-free reading and long-form note taking.

---

## Phased Implementation Roadmap

```
Phase 1: Architecture, Load-Order & Single Source of Truth
   │
   ├──> Phase 2: In-Buffer Completion & Navigation (Corfu Popups, Cape, Dumb-Jump)
   │
   ├──> Phase 3: Git Merge Conflict Resolution (Smerge Mode Leader Keys)
   │
   ├──> Phase 4: Interactive Project Build Tooling (Just Recipe Runner)
   │
   └──> Phase 5: Org-Roam Typography & Long-Form Reading Experience
```

---

## Phase 1: Architecture, Load-Order & Single Source of Truth

- **Scope**:
  - Move `rata-org-roam-dir` `defcustom` from `lisp/init-org.el` into `lisp/init-system.el` (within the `rata` group).
  - Update `lisp/init-khoj.el` to consume `(list rata-org-roam-dir)` instead of hardcoding `~/workspace/second-brain/org-roam/`.
  - Fix `simple-httpd` recipe in `lisp/init-org.el`: replace `skeeto/emacs-web-server` with `skeeto/emacs-httpd`.
  - Add `(require 'org-roam-protocol)` inside `use-package org-roam` in `lisp/init-org.el`.
- **Tests** (`tests/run-tests.el`):
  - `rata-test-org-roam-dir-bound-early`: assert `rata-org-roam-dir` is bound and stringp.
  - `rata-test-khoj-uses-rata-org-roam-dir`: assert `khoj-index-directories` equals `(list rata-org-roam-dir)`.
- **Verify**: `just lint && just compile && just batch-strict && just test-ert`.

---

## Phase 2: In-Buffer Completion & Navigation (Corfu Popups, Cape, Dumb-Jump)

- **Scope**:
  - `lisp/init-completion.el`:
    - Enable `corfu-popupinfo-mode 1` with `corfu-popupinfo-delay '(0.4 . 0.2)`.
    - Add `cape-elisp-symbol` to `completion-at-point-functions` in `emacs-lisp-mode`.
  - `lisp/init-dev.el`:
    - Configure `dumb-jump` as xref backend fallback when LSP is unavailable.
- **Tests** (`tests/run-tests.el`):
  - `rata-test-corfu-popupinfo-enabled`: assert `corfu-popupinfo-mode` is non-nil.
  - `rata-test-dumb-jump-xref-hook`: assert `dumb-jump-xref-activate` is available in `xref-backend-functions`.
- **Verify**: `just lint && just compile && just test-ert`.

---

## Phase 3: Git Ergonomics (Smerge Conflicts & Magit Commit Window Fix)

- **Scope**:
  - `lisp/init-dev.el`:
    - Bind `smerge-mode` leader keys under `SPC g m`:
      - `SPC g m n`: `smerge-next` (next conflict)
      - `SPC g m p`: `smerge-prev` (previous conflict)
      - `SPC g m u`: `smerge-keep-upper` (keep mine)
      - `SPC g m l`: `smerge-keep-lower` (keep theirs)
      - `SPC g m a`: `smerge-keep-all` (keep all)
      - `SPC g m b`: `smerge-keep-base` (keep base)
      - `SPC g m d`: `smerge-diff-base-upper` (diff base vs upper)
    - **Fix Magit commit window retention bug**:
      - Set `magit-bury-buffer-function` to `#'magit-restore-window-configuration` so
        exiting/finishing Magit cleanly restores the prior window layout.
      - Add a post-finish hook to `git-commit-post-finish-hook`: when a commit completes
        and the commit message window was in a secondary split window, ensure the window
        is deleted (`delete-window`) when `(> (count-windows) 1)` rather than leaving
        a duplicate/empty split window open.
- **Tests** (`tests/run-tests.el`):
  - `rata-test-smerge-leader-keys`: assert all `SPC g m` keys resolve to valid `commandp` symbols.
  - `rata-test-magit-post-finish-hook`: assert window cleanup hook is added to `git-commit-post-finish-hook`.
- **Verify**: `just lint && just compile && just test-ert`.

---

## Phase 4: Interactive Project Build Tooling (Just Recipe Runner)

- **Scope**:
  - `lisp/init-just.el`:
    - Implement `rata-just-run (&optional recipe)`:
      - Reads `just --summary` from the project root.
      - Prompts with `completing-read`.
      - Executes the recipe via `compile` (`(compile (format "just %s" choice))`).
    - Bind `rata-just-run` to `SPC p j` (project just) and `SPC c j` (compile just).
- **Tests** (`tests/run-tests.el`):
  - `rata-test-just-run-commandp`: assert `rata-just-run` is an interactive command.
  - Pure function test parsing `just --summary` output into recipe list.
- **Verify**: `just lint && just compile && just test-ert`.

---

## Phase 5: Org-Roam Typography & Long-Form Reading Experience

- **Scope**:
  - `lisp/init-org.el`:
    - Configure proportional fonts for Org headings and body text (`mixed-pitch-mode`), ensuring code blocks, tables, checkboxes, and properties remain monospaced.
    - Add distraction-free reading margins toggle (`visual-fill-column-mode` or `olivetti`) under `SPC t c` / `SPC o z`.
- **Tests** (`tests/run-tests.el`):
  - Assert typography hooks and toggles are `commandp` and load cleanly.
- **Verify**: `just lint && just compile && just test-ert`.

---

## Verification Honesty & Safety Protocol

1. **Safety with Private Data**:
   - Automated tests in `tests/run-tests.el` and `just test` must **NEVER** read from or write to `~/workspace/second-brain/` or `~/.authinfo.gpg`.
   - All tests bind `rata-org-roam-dir` to `temporary-file-directory` or throwaway temporary directories.
2. **Graceful Degradation**:
   - Missing external binaries (`just`, `enchant`, etc.) must disable only the affected feature and display a warning, never crashing Emacs initialization.
3. **No Autonomous Commits**:
   - In accordance with SAFETY_RULES, coding agents executing these phases must leave all changes uncommitted for operator review.
