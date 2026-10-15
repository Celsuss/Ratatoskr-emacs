# Plan — AI agent powerhouse: Coding & Second Brain (`plans/ai-agent-pillars.md`)

Status: **proposed** (written 2026-10-13). Future implementation sessions will execute
this plan phase by phase. No code was implemented during the initial planning session.
Each `## Phase N` below is one unit of work, done in interactive Claude Code via `/goal`
or interactive pair programming.

**This file is the progress record:** a phase is closed by appending ` [done]` to its
heading, or ` [blocked: <reason>]` when it needs operator intervention. The first heading
with neither marker is the next phase. Nothing is committed autonomously (SAFETY_RULES),
so git history is not the progress record — this file is.

---

## How to run this plan

In interactive Claude Code, in this repo, with one command:

```text
/goal Implement plans/ai-agent-pillars.md phase by phase, following its "Rules for each phase". Done when `grep -E '^## Phase' plans/ai-agent-pillars.md | grep -vcE '\[(done|blocked: .*)\]$'` prints 0, every [done] phase has a line under its heading recording a passing `just are-verify` run at the level it names, and the last message reports PASS/FAIL/NOT TESTED per area. Stop after 15 tries.
```

### Rules for each phase

1. Re-read the "Design" section and the target phase. Work on the first `## Phase N`
   heading with no `[done]` / `[blocked: ...]` marker, and only that one.
2. Follow `AGENTS.md` guidelines: test pure functions first, run verification commands,
   and preserve existing docstrings and architectural patterns.
3. Write ERT tests in `tests/run-tests.el` before the implementation code, and see them fail.
   Ensure test runs NEVER touch `~/workspace/second-brain/` or private credentials; tests
   must operate on temporary directories or mock fixtures.
4. Run verification (`just are-verify relevant` or `just are-verify full`, or `just test`).
   Never weaken, skip, or delete a test to get it green.
5. When it passes, append ` [done]` to the phase heading and add a one-line record under it:
   date, verification level run, PASS / FAIL / NOT TESTED per area.
6. If the phase needs an operator decision, or verification still fails after two honest
   fix attempts, append ` [blocked: <one-line reason>]` and stop.
7. Never commit autonomously (SAFETY_RULES).

---

## Goal & Strategic Vision

Transform **Ratatoskr-emacs** into a world-class AI agent powerhouse by bridging deep
Emacs ergonomics (Magit, Ediff, Projectile, Tree-sitter, Org-roam) with autonomous agent
mechanics (Agent-Shell ACP, Agent-Center overview, Worktree isolation, Claude-Loop) and
the operator's personal knowledge base (`~/workspace/second-brain/org-roam/`).

### The Three Pillars

```
                     +---------------------------------------+
                     |        Ratatoskr-emacs AI Core        |
                     +---------------------------------------+
                                         |
     +-----------------------------------+-----------------------------------+
     |                                   |                                   |
     v                                   v                                   v
+------------------------+  +------------------------+  +------------------------+
|       PILLAR I:        |  |       PILLAR II:       |  |      PILLAR III:       |
|    Advanced Coding     |  |   AI-Powered Second    |  |    Synergistic Code    |
|    Agent Workflows     |  |      Brain & PKM       |  |   ↔ Second Brain Hub   |
+------------------------+  +------------------------+  +------------------------+
| * Multi-file Diff &    |  | * Org-Roam MCP Bridge  |  | * Auto-Capture Dev-Log |
|   Review Hub (Magit/   |  |   (uvx org-roam-mcp)   |  |   & ADRs on Finish     |
|   Ediff / Comments)    |  | * Ambient Semantic     |  | * Spec-Driven Agent    |
| * Tree-sitter Repo     |  |   Connections Sidebar  |  |   Spawning from Roam   |
|   Map Generator        |  | * Vault-Grounded RAG   |  | * Troubleshooting      |
| * Personas & Modes     |  |   (Khoj / gptel)       |  |   Knowledge Harvest    |
| * Hierarchical Rules   |  | * Literature Synthesizer| | * {{notes}} Context    |
|   (.ratarules)         |  |   (elfeed-hn -> roam)  |  |   Prompt Injection     |
+------------------------+  +------------------------+  +------------------------+
```

1. **Pillar I: Advanced Coding Agent Workflows** — Bring the best UX features from Cursor
   (Composer, multi-file diff review, scoped rules), Windsurf (proactive feedback loops),
   Roo Code (persona/mode switching), and Aider (Tree-sitter repo map) into Emacs.
2. **Pillar II: AI-Powered Second Brain & PKM** — Transform `org-roam` from a passive note
   repository into an active cognitive partner, inspired by Obsidian Smart Connections
   (ambient discovery) and Copilot (grounded vault RAG), backed by an MCP bridge.
3. **Pillar III: The Synergistic Bridge (Code ↔ Second Brain)** — Connect engineering
   execution with long-term memory: auto-capturing Architecture Decision Records (ADRs)
   and dev-logs when agent worktrees finish, spawning agents directly from Org-roam project
   specs, and harvesting troubleshooting solutions into the knowledge base.

---

## What Exists Today (Verified in Codebase)

| Component | File | Current Capabilities |
|---|---|---|
| **Agent Center** | `lisp/init-agent-center.el` | Pinned `*Agents*` side-window overview across all persp layouts; state tracking (`needs-input`, `error`, `done`, `working`, `starting`, `ready`); dim activity line (A2); `SPC a i o` / `SPC a i n`. |
| **Agent Worktree** | `lisp/init-agent-worktree.el` | Spawns git worktree per task (`agent/<slug>`), records base branch in `branch.<b>.rataAgentBase`, switches layout, archives transcripts, finishes on clean merge. (B6) |
| **Agent Prompts** | `lisp/init-agent-prompts.el` | Reusable Markdown prompts (`prompts/*.md`); placeholder expansion (`{{region}}`, `{{file}}`, `{{diff}}`, `{{error}}`, `{{project}}`); non-submitting insertion. (C12) |
| **Claude Loop** | `lisp/init-claude-loop.el` | Autonomous checklist loop; trampoline state machine; epoch staleness tracking; tool permission auditing; verify baseline; budget caps. |
| **Unified LLM** | `lisp/init-llm.el` | Unified `rata-llm-providers` plist configuring `gptel`, `ellama`, and `aidermacs`; `agent-shell` over ACP (`claude-agent-acp`, `pi-acp`); local leader commands. |
| **MCP (Experimental)** | `lisp/init-mcp.el` | Basic stub for `mcp` client (`SPC a m`). |
| **Khoj 2.0** | `lisp/init-khoj.el` | Self-hosted semantic search & chat indexing `~/workspace/second-brain/org-roam/` (`SPC a i k`). |
| **Org & Roam** | `lisp/init-org.el` | Org-roam zettelkasten, project/meeting/tool-eval/troubleshooting capture templates, dynamic `:hastodo:` agenda integration, task auto-sorting. |
| **Hacker News Reader** | `lisp/init-elfeed-hn.el` | In-buffer reader view of HN stories and Algolia comment threads inside `elfeed`. |

---

## Inspiration & Benchmark Analysis

### 1. Cursor (Composer, Rules & Multi-File Diffs)
- **Composer Diff Review**: Displays multi-file changes with granular accept/reject (by file
  or hunk). In Emacs, Magit and Ediff are uniquely suited for this, but currently an agent
  branch in `init-agent-worktree.el` lacks an integrated "Agent Review Transient" to browse
  all branch changes, inspect side-by-side diffs, and send change requests back to the agent.
- **Hierarchical Rules (`.cursorrules` / `.cursor/rules/*.mdc`)**: Scoped guidelines loaded
  by directory or task. Emacs can automatically detect `.ratarules` in the project root and
  append them to agent system prompts.

### 2. Windsurf (Cascade)
- **Proactive Context & Self-Healing**: Windsurf automatically catches compiler diagnostics
  and test failures. In Ratatoskr, we can provide an automated feedback bridge: when `flycheck`
  or `just test` fails after an agent turn, one command packages the diagnostic error and
  sends it straight back to the active agent shell.

### 3. Roo Code / Cline (Personas & MCP Hub)
- **Modes / Personas**: Distinct personas (`Architect` with high-reasoning models and
  read-only tools; `Code` with fast editing models; `Ask` for exploratory Q&A; `Reviewer`
  for security & test critique).
- **Model Context Protocol (MCP)**: Connecting agents directly to external tools, databases,
  and knowledge bases.

### 4. Obsidian Smart Connections & Copilot
- **Smart Connections**: An ambient sidebar that uses vector embeddings to continuously
  surface related notes as you read or write in your vault.
- **Vault-Grounded Copilot**: Conversational RAG with strict citations of note titles and
  node IDs.

### 5. Aider (Tree-sitter Repo Map)
- **Repository Map**: Extracts an AST summary (classes, types, function signatures) across
  the codebase using Tree-sitter. Gives the agent a comprehensive structural map of the
  entire project for a fraction of the token cost of full file reading.

---

## Design Specifications

### Pillar I: Advanced Coding Agent Workflows

#### 1. Interactive Agent Diff & Review Hub (`lisp/init-agent-review.el`)

- **Module Location**: `lisp/init-agent-review.el`, loaded after `init-agent-worktree.el` and `init-dev.el` (Magit).
- **Core Motivation**: Brings Cursor Composer & GitHub PR review ergonomics directly into Emacs. When an autonomous agent completes code changes in its worktree (`.agent-shell/worktrees/<slug>`), the operator needs a dedicated, friction-free cockpit to:
  1. Inspect multi-file diffs across the entire branch against its recorded base (`base...HEAD`).
  2. Navigate hunks, fold files/sections, and run side-by-side comparisons via Ediff.
  3. Attach granular review comments and corrective directives to specific files and hunks in-memory.
  4. Dispatch staged directives back into the active `agent-shell` in one keystroke, steering the agent iteratively.
  5. Approve and finalize the worktree directly from the review buffer once satisfied.

##### 1.1 Architecture & Magit Mode Derivation
- **Inherit Directly from `magit-diff-mode`**:
  ```elisp
  (define-derived-mode rata-agent-review-mode magit-diff-mode "Agent-Review"
    "Major mode for reviewing agent worktree diffs against their base branch."
    :group 'rata-agent-review)
  ```
- **Why Inherit from `magit-diff-mode`?**
  - **No Reinvention**: Automatically inherits `magit-section` folding (`TAB` / `S-TAB`), hunk syntax highlighting, hunk jumping (`n` / `p`), file jumping (`RET`), and side-by-side comparison (`e` via `magit-ediff-dwim`).
  - **Clean Buffer Isolation**: Operates in its own dedicated buffer `*Agent Review: <branch>*` created via `magit-setup-buffer-internal` with `:buffer` keyword. Never mutates, dirties, or interferes with standard `magit-status` or generic diff buffers.
  - **Deterministic Revision Range**: Agent worktrees created by `init-agent-worktree.el` always record their source branch in `branch.<branch>.rataAgentBase`. The review range is strictly computed as `base...HEAD`.

##### 1.2 Data Structures & Buffer-Local State
The review buffer maintains ephemeral, in-memory state:
- `rata-agent-review--worktree`: Absolute directory path to the worktree root.
- `rata-agent-review--branch`: Current worktree branch name (e.g. `"agent/fix-auth"`).
- `rata-agent-review--base`: Base branch name recorded in git config (e.g. `"main"`).
- `rata-agent-review--shell-buffer`: Associated `agent-shell` buffer handle.
- `rata-agent-review--directives`: In-memory list of pending review directives. Each directive is a plist:
  ```elisp
  (:id 1
   :file "lisp/init-auth.el"
   :line 42
   :hunk "@@ -40,6 +40,8 @@\n..."
   :comment "Ensure nil token is handled gracefully with user-error"
   :created-at 1728900000.0)
  ```
- `rata-agent-review--next-id`: Monotonic counter for assigning unique integer IDs to directives.

##### 1.3 Buffer Layout & Custom Magit Sections
`rata-agent-review-mode` sets `magit-diff-sections-hook` buffer-locally to insert three structured sections:
```elisp
(setq-local magit-diff-sections-hook
            '(rata-agent-review-insert-header
              rata-agent-review-insert-directives
              magit-insert-diff))
```

1. **Agent Task Header Section** (`rata-agent-review-insert-header`):
   ```text
   Agent Review: agent/add-caching (Worktree: ~/repo/.agent-shell/worktrees/add-caching)
   Base Branch:  main (Range: main...HEAD)
   Agent Shell:  *agent-shell: add-caching* [Status: done]
   Diff Stats:   3 files changed, 54 insertions(+), 12 deletions(-)
   ```
2. **Pending Review Directives Section** (`rata-agent-review-insert-directives`):
   - Staged directives awaiting dispatch to the agent:
   ```text
   Pending Review Directives (2 queued):
     [#1] lisp/cache.el:42
          Directive: Add docstring explaining the TTL eviction strategy.
     [#2] lisp/cache.el (Hunk @@ -80,10 +80,15 @@)
          Directive: Use `remhash' instead of setting nil.

   Actions: [s/C-c C-c] Send to agent  [d] Delete directive  [c] Add comment at point
   ```
   - When empty, prints a subtle hint: `(No directives queued. Press 'c' on a file or hunk to add review feedback)`.
3. **Multi-File Diff Section** (`magit-insert-diff`):
   - Standard Magit diff section tree rendering `base...HEAD`.
   - Supports all native Magit navigation, section toggling, and ediff commands.

##### 1.4 Context Extraction & Interactive Review Workflow
- **Context Extraction at Point (`rata-agent-review--context-at-point`)**:
  - Uses `(magit-current-section)` to inspect point location:
    - If on or inside a file section: resolves file path via `(magit-diff--file)` or `(oref (magit-diff--file-section) value)`.
    - If inside a hunk section (`magit-section-match 'hunk`): extracts target line number via `(magit-diff-hunk-line section nil)` and hunk text slice via `(buffer-substring-no-properties (oref section start) (oref section end))`.
    - If on file heading: line and hunk are nil.
  - Returns plist: `(:file file :line line :hunk hunk)`.

- **Keybindings (`rata-agent-review-mode-map`)**:
  - `c` (`rata-agent-review-comment`):
    - Extracts context at point (`file`, `line`, `hunk`).
    - Prompts operator for directive/comment in the minibuffer (e.g. `Comment on cache.el:42: `).
    - Appends record to buffer-local `rata-agent-review--directives`.
    - Calls `magit-refresh` to immediately update the Pending Directives section.
  - `d` or `k` (`rata-agent-review-delete-directive`):
    - If point is on a directive in the Directives section, deletes that directive.
    - Otherwise prompts via `completing-read` to pick a directive to remove.
    - Refreshes buffer.
  - `s` or `C-c C-c` (`rata-agent-review-send`):
    - Validates that directives list is non-empty.
    - Formats directives into Markdown prompt using `rata-agent-review-format-prompt`.
    - Locates associated agent shell (`rata-agent-review--shell-buffer` or persp layout shell).
    - Injects text via `agent-shell-insert`. If agent is currently busy (`shell-maker-busy`), enqueues via `agent-shell-prompt-queue`.
    - Clears `rata-agent-review--directives` and calls `magit-refresh`.
    - Notifies operator: `Dispatched N review directive(s) to agent shell`.
  - `a` (`rata-agent-review-jump-to-shell`): Switches focus to the associated `agent-shell` window.
  - `f` (`rata-agent-review-finish-worktree`): Invokes `rata-agent-worktree-finish-at` on the worktree. If merged and cleaned up successfully, kills the review buffer.
  - `e` (`magit-ediff-dwim`): Inherited from Magit. Launches side-by-side interactive Ediff against base.
  - `g` / `g r` (`magit-refresh`): Re-runs git diff and reconciles agent status and directives.
  - `TAB` (`magit-section-toggle`): Toggles folding of hunks and files.
  - `q` (`quit-window`): Buries or closes the review window.

##### 1.5 Pure Prompt Formatting Protocol
`rata-agent-review-format-prompt (branch base directives)` is a pure, side-effect-free function that converts directive records into a structured Markdown prompt for the agent:
```markdown
## Code Review Directives for `agent/add-caching` (Base: `main`)

Please address the following review directives in your next changes:

### Directive 1: `lisp/cache.el` (Line 42)
**Feedback**: Add docstring explaining the TTL eviction strategy.

### Directive 2: `lisp/cache.el`
**Feedback**: Use `remhash` instead of setting nil.
```diff
@@ -80,10 +80,15 @@
-  (puthash key nil table)
+  (remhash key table)
```

Please update the code accordingly and verify your changes.
```

##### 1.6 Integration & Entry Points
- **From Agent Center (`init-agent-center.el`)**:
  - Bound to `r` in `rata-agent-center-mode-map`: opens `rata-agent-review` for the worktree corresponding to the selected agent row.
- **From Worktree / Dev Buffers (`init-agent-worktree.el`)**:
  - Global leader `SPC a i r` (`rata-agent-review`): detects whether current buffer is in an agent worktree; if so, opens its review buffer immediately; if not, prompts to pick from live agent worktrees.
- **Window Management & Shackle (`init-system.el`)**:
  - Shackle rule: `(:name "^\\*Agent Review:" :regexp t :select t :same t)` ensuring full-window or dedicated primary view without side-window crowding.

##### 1.7 Implementation Sub-Phases (Execution Plan for Phase 2)
The implementation is broken down into four test-driven sub-phases:
1. **Sub-Phase 2.1: Pure Data Model, Prompt Formatter & Context Extraction**:
   - Write ERT tests for `rata-agent-review-format-prompt` with varying directive shapes (file-only, file+line, file+hunk, multiple directives).
   - Implement directive CRUD helpers (`add`, `delete`, `clear`).
   - Implement `rata-agent-review-format-prompt` (pure).
   - Implement `rata-agent-review--extract-context` helper for section objects.
2. **Sub-Phase 2.2: Buffer Setup, Mode Derivation & Custom Sections**:
   - Write ERT tests for `rata-agent-review-mode` inheritance and buffer setup in a mock repository.
   - Define `rata-agent-review-mode` derived from `magit-diff-mode`.
   - Implement `rata-agent-review-insert-header` and `rata-agent-review-insert-directives`.
   - Implement `rata-agent-review-open (dir)` using `magit-setup-buffer-internal` with `:buffer` and `:directory`.
   - Configure local `magit-diff-sections-hook`.
3. **Sub-Phase 2.3: Interactive Review Commands & Agent Shell Dispatch**:
   - Write ERT tests with stubbed `agent-shell-insert` and mocked prompts.
   - Implement `c` (`rata-agent-review-comment`) and `d` (`rata-agent-review-delete-directive`).
   - Implement `s` / `C-c C-c` (`rata-agent-review-send`) with fallback to `agent-shell-prompt-queue`.
   - Implement `a` (`rata-agent-review-jump-to-shell`) and `f` (`rata-agent-review-finish-worktree`).
4. **Sub-Phase 2.4: Agent Center & Global Integration, Keybindings & Verification**:
   - Bind `r` in `rata-agent-center-mode-map` (`*Agents*`).
   - Bind `SPC a i r` in `rata-leader`.
   - Add `(rata-load-module 'init-agent-review)` in `init.el`.
   - Run complete suite: `just lint`, `just compile`, `just test`.

##### 1.8 Safety & Invariants
- **Non-Destructive**: Staging review comments never modifies working copy files or git commits. Directives live in-memory in buffer-local storage.
- **Explicit Dispatch**: Directives are only transmitted when the operator presses `s` / `C-c C-c`.
- **Merge Integrity**: Worktree cleanup (`f`) continues to enforce `rata-agent-worktree-finish-at` invariants (no dirty files, no unsaved buffers, branch must be merged into base before removal).
- **Graceful Fallbacks**: If the agent shell is closed or busy, directives are not lost; the operator is warned and offered the option to enqueue or view the formatted prompt.

#### 2. Tree-sitter Repo Map Context Generator (`lisp/init-agent-repomap.el`)
- **Mechanism**:
  - Leverages Emacs 30 built-in `treesit` (or `treesit-auto` from `init-lang.el`).
  - Scans tracked files in the current project (respecting `.gitignore`).
  - Queries Tree-sitter AST nodes for top-level definitions:
    - Rust: `struct_item`, `enum_item`, `function_item`, `trait_item`.
    - Go: `type_declaration`, `function_declaration`, `method_declaration`.
    - Python: `class_definition`, `function_definition`.
    - Elisp / C / C++: corresponding definitions.
  - Generates a compact Markdown code block summarizing signatures without bodies:
    ```rust
    // src/engine.rs
    pub struct AgentEngine { ... }
    impl AgentEngine {
        pub fn new(config: Config) -> Result<Self>;
        pub async fn step(&mut self) -> Result<StepOutcome>;
    }
    ```
  - Pure function `rata-agent-repomap-generate (root &optional max-tokens)`.
  - Integrates with `init-agent-prompts.el` via placeholder `{{repomap}}`.

#### 3. Agent Personas & Mode Switching
- **Mechanism**:
  - Declarative persona table in `init-llm.el`:
    - `Architect`: Reasoning model (e.g. Claude 3.7 / o3-mini / DeepSeek-R1), read-only tools,
      system prompt emphasizing system architecture, failure modes, and test plans.
    - `Implementer`: Coding model (Claude 3.5 Sonnet / Qwen 2.5 Coder), read/write/bash tools.
    - `Reviewer`: Security and test-audit system prompt.
    - `Second-Brain`: Note-synthesis system prompt with Org syntax rules.
  - Bound under `, m` (mode/model) in `agent-shell` and `gptel-agent`.

#### 4. Hierarchical Project Rules (`.ratarules`)
- **Mechanism**:
  - Function `rata-agent-project-rules (dir)` traverses from `dir` up to project root.
  - Concatenates `.ratarules` or `.cursorrules` if present.
  - Automatically appended to `:session-meta` system prompt in `agent-shell` and
    `rata-claude-loop--common-args`.

---

### Pillar II: AI-Powered Second Brain & PKM (`org-roam`)

#### 5. Org-Roam MCP Server Bridge (`lisp/init-mcp.el` / `lisp/init-llm.el`)
- **Tool**: `org-roam-mcp` (Python-based, executed on-demand via `uvx org-roam-mcp`).
- **Why `uvx`**: Operates directly on the SQLite database `~/workspace/second-brain/org-roam/org-roam.db`
  and Org files. Requires NO Emacs daemon, causes NO Elisp blocking, and provides fast
  compiled SQLite queries.
- **Tools exposed to Agent-Shell & Claude Code**:
  - `search_nodes`: Semantic & title search of notes.
  - `get_node_content`: Reads complete note content by ID or file path.
  - `get_backlinks`: Retrieves forward and backward link graph.
  - `create_note`: Appends captured notes into `inbox.org` or creates timestamped nodes.
- **Safety Gate**: Configuration points explicitly to `rata-org-roam-dir` without hardcoding
  absolute user paths in committed git files.

#### 6. Ambient Semantic Connections Sidebar (`lisp/init-roam-ai.el`)
- **Buffer**: `*Roam Connections*` (right side-window, dedicated, 40 cols).
- **Behavior**:
  - When editing or viewing an Org-roam buffer, automatically surfaces the top 5
    semantically related notes from the second brain.
  - Embeddings source: Local Ollama `nomic-embed-text` (from `rata-llm-providers`) or Khoj API.
  - Trampoline & Debounce: Query runs asynchronously via `url-retrieve` or curl process,
    debounced by 1.5 seconds of idle time. Never stalls the editor.
  - Displays: Note title, similarity score percentage, matching excerpt snippet.
  - Keys: `RET` visits note in main window; `i` inserts an `[[id:...][Title]]` link at point
    in the active note; `q` closes sidebar.

#### 7. Literature & Feed Synthesizer (`lisp/init-elfeed-hn.el` / `lisp/init-org.el`)
- **Workflow**:
  - In `*elfeed-entry*` (including HN threads rendered by `init-elfeed-hn.el`), press `SPC a r s`
    (`rata-elfeed-synthesize-to-roam`).
  - Asynchronously sends article text + discussion summary to the default LLM.
  - Formats an atomic Org-roam literature note:
    - Summary of the thesis and key insights.
    - Notable perspectives from the comment thread.
    - Source URL and date.
    - Tags (`:reading:literature:`).
  - Saves note directly into `rata-org-roam-dir` and registers it in `org-roam-db`.

---

### Pillar III: The Synergistic Bridge (Code ↔ Second Brain)

#### 8. Auto-Capture Dev-Logs & ADRs on Worktree Finish (`lisp/init-agent-worktree.el`)
- **Hook**: Extended finish flow in `rata-agent-worktree-finish-at`.
- **Workflow**:
  - Before destroying the worktree and branch, ask: `Capture Dev-Log/ADR to Second Brain? (y/n)`.
  - When yes:
    - Reads git log and diff between `branch.<b>.rataAgentBase` and HEAD.
    - Prompts LLM for a structured summary:
      - **Problem & Goal**
      - **Architectural Decisions & Rationale**
      - **Files Modified**
      - **Lessons Learned & Gotchas**
    - Creates an Org-roam note: `%<%Y%m%d%H%M%S>-devlog-${slug}.org` tagged `:devlog:project:`.
    - Automatically links to the project's Org-roam node if one exists.
    - Preserves institutional memory forever.

#### 9. Spec-Driven Task Spawning from Org-Roam (`lisp/init-org.el` / `lisp/init-agent-worktree.el`)
- **Workflow**:
  - In any Org-roam project note (template `p`), navigate to a task heading (e.g. `*** TODO Implement feature X`).
  - Press `SPC o r a` (`rata-org-roam-spawn-agent`).
  - Command extracts:
    - Project repository path (from `#+property: header-args :dir ...` or property drawer).
    - Milestone and Goal from parent headings.
    - Task description and acceptance criteria.
  - Automatically executes `rata-agent-worktree-create` in that repository and initializes
    the agent shell with the full context of the second-brain specification!

#### 10. Troubleshooting Knowledge Harvesting
- **Workflow**:
  - Command `SPC a i s T` (`rata-agent-harvest-troubleshooting`) in an agent shell or dev buffer.
  - Extracts the latest compiler error / traceback and the agent's successful resolution.
  - Populates Org-roam template `T` (`troubleshooting.org`) in `second-brain`:
    - Environment & tools.
    - Error symptom.
    - Root cause.
    - Fix / workaround.

---

## Phased Implementation Roadmap

```
Phase 1: Second Brain MCP Bridge (org-roam-mcp + init-mcp.el)
   │
   ├──> Phase 2: Magit-Derived Agent Review Mode (init-agent-review.el)
   │
   ├──> Phase 3: Second Brain Context & Spec-Driven Spawning (init-agent-prompts + init-org)
   │
   ├──> Phase 4: Ambient Semantic Connections Sidebar (init-roam-ai.el)
   │
   ├──> Phase 5: Tree-sitter Repo Map Context Generator (init-agent-repomap.el)
   │
   └──> Phase 6: Automated Dev-Log & ADR Capture on Worktree Finish (init-agent-worktree.el)
```

---

## Phase 1: Second Brain MCP Bridge (`org-roam-mcp`)

- **Scope**:
  - Configure `init-mcp.el` and `init-llm.el` to register `org-roam-mcp` for `agent-shell`
    and Claude Code sessions.
  - Define `rata-mcp-org-roam-command` defaulting to `("uvx" "org-roam-mcp")`.
  - Pass environment variables dynamically: `ORG_ROAM_DIR` and `ORG_ROAM_DB_PATH` derived
    from `rata-org-roam-dir`.
  - Ensure graceful degradation: if `uvx` or `org-roam-mcp` is absent, warn once and disable
    the tool without interrupting agent-shell startup.
- **Tests** (`tests/run-tests.el`):
  - Pure function test verifying command generation and environment variable derivation.
  - Mock test asserting tool definition registration for agent-shell.
- **Verify**: `just are-verify relevant`.

---

## Phase 2: Magit-Derived Agent Review Mode (`init-agent-review.el`) [done]

- **Scope & Objective**:
  Implement `lisp/init-agent-review.el` to provide an interactive multi-file diff and review hub
  inheriting from `magit-diff-mode`. Allows staging in-memory directives against agent worktrees and
  dispatching structured feedback back to `agent-shell` (implementing §1.1–§1.8 of Pillar I).
- **Sub-Phase Execution Sequence**:
  - **Sub-Phase 2.1: Data Model, Pure Prompt Formatter & Context Extraction**:
    - Pre-requisite ERT tests:
      - `rata-test-agent-review-format-prompt`: validates Markdown prompt string formatting for file-only,
        file+line, and file+line+hunk directives, asserting proper section titles and code fences.
      - `rata-test-agent-review-directive-crud`: verifies adding, listing, unique ID generation, and deletion
        of directive plists in an in-memory list.
      - `rata-test-agent-review-extract-context`: tests extracting `(:file ... :line ... :hunk ...)` from
        synthetic Magit file and hunk sections.
    - Implementation:
      - Define `rata-agent-review-format-prompt (branch base directives)` (pure).
      - Define directive data structures and CRUD helpers (`rata-agent-review--add-directive`,
        `rata-agent-review--delete-directive`).
      - Define context extractor `rata-agent-review--context-at-point` evaluating `(magit-current-section)`.
  - **Sub-Phase 2.2: Buffer Setup, Mode Derivation & Custom Sections**:
    - Pre-requisite ERT tests:
      - `rata-test-agent-review-mode-derivation`: asserts `(provided-mode-derived-p 'rata-agent-review-mode 'magit-diff-mode)`.
      - `rata-test-agent-review-buffer-setup`: inside `rata-test-agent-worktree--with-repo`, creates an agent
        worktree with a commit, runs `rata-agent-review-open`, and asserts buffer name is `*Agent Review: <branch>*`,
        mode is `rata-agent-review-mode`, and default directory matches the worktree root.
      - `rata-test-agent-review-sections`: checks that header and directives sections render with proper headings.
    - Implementation:
      - Define major mode `(define-derived-mode rata-agent-review-mode magit-diff-mode "Agent-Review" ...)`.
      - Implement section printer `rata-agent-review-insert-header` (displays worktree path, branch, base, agent state, diffstat).
      - Implement section printer `rata-agent-review-insert-directives` (displays pending directives or guidance when empty).
      - Set local `magit-diff-sections-hook` to `'(rata-agent-review-insert-header rata-agent-review-insert-directives magit-insert-diff)`.
      - Implement `rata-agent-review-open (dir)` resolving base via `rata-agent-worktree--base` and invoking `magit-setup-buffer-internal`.
  - **Sub-Phase 2.3: Interactive Review Commands & Agent Shell Dispatch**:
    - Pre-requisite ERT tests:
      - `rata-test-agent-review-comment-command`: stubs `read-string`, calls `rata-agent-review-comment`, and verifies
        directive is added to buffer-local list and buffer refreshed.
      - `rata-test-agent-review-send-dispatch`: stubs `agent-shell-insert`, verifies formatted prompt is sent,
        directives list is cleared, and confirmation message displayed.
      - `rata-test-agent-review-send-queued`: stubs `shell-maker-busy` returning t, verifies fallback to `agent-shell-prompt-queue`.
    - Implementation:
      - Implement `c` (`rata-agent-review-comment`) and `d` (`rata-agent-review-delete-directive`).
      - Implement `s` / `C-c C-c` (`rata-agent-review-send`) dispatching via `agent-shell-insert` / `agent-shell-prompt-queue`.
      - Implement `a` (`rata-agent-review-jump-to-shell`) and `f` (`rata-agent-review-finish-worktree`).
      - Inherit Magit's `TAB`, `e` (`magit-ediff-dwim`), `RET`, and `g`/`g r` (`magit-refresh`).
  - **Sub-Phase 2.4: Agent Center & Global Integration, Keybindings & Verification**:
    - Pre-requisite ERT tests:
      - `rata-test-agent-review-panel-key`: verifies `r` in `rata-agent-center-mode-map` invokes review for selected row.
      - `rata-test-agent-review-leader-key`: verifies `SPC a i r` is bound in evil normal/visual states.
      - `rata-test-agent-review-shackle-rule`: verifies `shackle-rules` routes `*Agent Review:` buffers to same window and selects.
    - Implementation:
      - Add `r` keybinding in `rata-agent-center-mode-map`.
      - Add `SPC a i r` in `rata-leader` (`init-evil.el` / `init-agent-review.el`).
      - Add shackle rule in `init-system.el` for `*Agent Review: .*`.
      - Add `(rata-load-module 'init-agent-review)` in `init.el` after `init-agent-prompts`.
      - Document module in `AGENTS.md`.
- **Verification Record**:
  - `just lint`: PASS
  - `just compile`: PASS
  - `just test`: PASS (221/221 ERT tests passing, 4/4 work-agenda tests passing, clean batch startup)
- **Verify**: `just are-verify relevant` (or `just test`).

---

## Phase 3: Second Brain Context & Spec-Driven Spawning

- **Scope**:
  - Proactive Error Feedback Loop:
    - Implement `rata-agent-send-last-error` (`SPC a i s e`): extracts active
      Flycheck error at point or last error block from `*compilation*`, formats
      with file and line context, and inserts into active agent shell.
  - Hierarchical Project Rules:
    - Implement `rata-agent-project-rules (dir)`: discovers `.ratarules` or
      `.cursorrules` from current directory up to project root.
    - Appends discovered rules to agent-shell initial prompt context.
  - Update `init-agent-prompts.el`:
    - Add `{{notes}}` placeholder.
    - Add `rata-agent-prompt--notes-at-point`: reads selected region or headline from current Org buffer.
  - Implement `rata-org-roam-spawn-agent` in `init-org.el`:
    - Reads task headline, parent goal, and repository directory property.
    - Calls `rata-agent-worktree-create` and launches agent-shell with spec prompt.
    - Bound to `SPC o r a` in `org-mode-map`.
- **Tests** (`tests/run-tests.el`):
  - Pure expansion test for `{{notes}}` placeholder.
  - Spec extractor test on a synthetic Org buffer with Goal and TODO headings.
  - Pure test for `rata-agent-project-rules` on nested mock directories.
  - Pure test formatting Flycheck/compilation errors for agent shell injection.
- **Verify**: `just are-verify relevant`.

---

## Phase 4: Ambient Semantic Connections Sidebar (`init-roam-ai.el`)

- **Scope**:
  - Create `lisp/init-roam-ai.el`.
  - Provide `rata-roam-ai-connections-mode` and toggle `rata-roam-ai-toggle` (`SPC o r s`).
  - Side-window displaying top 5 semantically similar notes.
  - Embedding queries dispatched asynchronously via curl / `url-retrieve` to Ollama or Khoj.
  - Debounced idle timer (1.5 s).
  - Evil navigation keys (`RET` visit, `i` insert link, `q` quit).
- **Tests** (`tests/run-tests.el`):
  - Pure function parsing similarity JSON payload into tabulated list entries.
  - Debounce timer lifecycle test in temp buffer.
- **Verify**: `just are-verify relevant`.

---

## Phase 5: Tree-sitter Repo Map Context Generator (`init-agent-repomap.el`)

- **Scope**:
  - Create `lisp/init-agent-repomap.el`.
  - Implement AST extraction queries for Rust, Go, Python, Elisp, and C/C++.
  - Generate formatted summary string respecting token limits.
  - Add `{{repomap}}` placeholder to `init-agent-prompts.el`.
  - Command `rata-agent-repomap-copy` / `rata-agent-repomap-insert`.
- **Tests** (`tests/run-tests.el`):
  - Extraction tests on small synthetic code samples (Rust struct, Python class, Go func).
  - Token-bound truncation test.
- **Verify**: `just are-verify relevant`.

---

## Phase 6: Automated Dev-Log & ADR Capture on Worktree Finish

- **Scope**:
  - Extend `rata-agent-worktree-finish-at` in `init-agent-worktree.el`.
  - Prompt user: `Capture Dev-Log to Second Brain?`.
  - On confirmation:
    - Summarizes worktree commits and diff.
    - Creates timestamped Org-roam file `%<%Y%m%d%H%M%S>-devlog-${slug}.org` in `rata-org-roam-dir`.
    - Updates `org-roam-db`.
  - Command `rata-agent-harvest-troubleshooting` (`SPC a i s T`) to capture bug fixes into `troubleshooting.org`.
- **Tests** (`tests/run-tests.el`):
  - Pure function formatting dev-log Org content from commit messages and diff metadata.
  - Test verifying no write occurs if operator declines prompt.
- **Verify**: `just are-verify full`.

---

## Verification Honesty & Safety Protocol

1. **Safety with Private Second Brain Data**:
   - Automated tests in `tests/run-tests.el` and `just test` must **NEVER** read from or write to
     `~/workspace/second-brain/`.
   - All tests must bind `rata-org-roam-dir` to `temporary-file-directory` or throwaway
     mock directories.
2. **Graceful Degradation**:
   - Missing external binaries (`uvx`, `org-roam-mcp`, `ollama`, `tree-sitter`) must disable
     only the specific feature and display a warning, never crashing Emacs initialization.
3. **No Autonomous Commits**:
   - In accordance with `.are/rules/SAFETY_RULES.md`, coding agents executing these phases
     must leave all changes uncommitted for operator review.
