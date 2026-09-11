# Decisions

Things settled, so a future session does not re-litigate them. Record the reasoning, not
just the outcome. If you overturn one, edit it in place and say when and why — do not add a
contradicting entry below it.

---

## D-001 — ARE is markdown + a path map + three bash scripts. Nothing more.

**2026-08-19, ARE bootstrap.**

No vector store, no embeddings, no index database, no new dependency. The repository is ~5.2k
lines of Elisp across 36 modules; `grep`, `git` and a 60-row table in
[../knowledge/MODULES.md](../knowledge/MODULES.md) retrieve from it faster and more reliably
than anything semantic would, and cost nothing to keep correct.

Revisit only with evidence: if context generation starts missing relevant knowledge, or the
knowledge base outgrows what an agent can navigate by index. Not before.

## D-002 — ARE points at `AGENTS.md`; it does not restate it

**2026-08-19.**

`AGENTS.md` is the authoritative, actively-maintained guide to conventions, module purposes,
`use-package` structure and keybinding patterns. Verified accurate at commit `1d38bd8`: its
module load-order list matches `init.el` line for line, and its `init-claude-loop.el` section
matches the implementation.

Copying it into `.are/knowledge/` would create a second source of truth that drifts. So ARE
knowledge pages add only what `AGENTS.md` lacks: **risk, blast radius, what the tests do and
do not prove, and the invariants a change can silently violate.** When they overlap, the
ARE page links rather than repeats.

Consequence: `AGENTS.md` becoming wrong is a MEDIUM-risk event, and is why it carries an
ARE section pointing back here.

## D-003 — `SPEC.md` is historical intent, not truth

**2026-08-19.**

2408 lines, self-labelled "Draft v8 — 2026-02-24", and demonstrably drifted:

- §2 marks `init-dashboard` as `TODO`; it is implemented, 325 lines.
- §2's module list predates the split of `init-lang` into per-language modules (commit
  `bebc14d`), so it does not mention `init-rust`, `init-go`, `init-python`, `init-cpp`,
  `init-cmake`, `init-terraform`, `init-just`, `init-docker`, `init-markdown`, `init-yaml`,
  `init-ansible`, `init-jupyter`, `init-helm` or `init-pkgbuild` as separate files.
- §3 marks the elpaca lockfile "DONE"; the `just` targets exist but no lockfile is committed
  and none exists on disk.

It is also the single largest token trap in the repository. **Do not read it whole. Do not
treat any status marker in it as current. `grep` it for design rationale only.** `init.el`
and `AGENTS.md` are the truth about what exists.

Not rewritten: bringing 2408 lines back into sync is a real task with no reliability payoff,
and would bury the ARE bootstrap diff. Flagged instead, in
[../INDEX.md](../INDEX.md) §6 and here.

## D-004 — `just test` keeps its exact current meaning; the gate moves instead

**2026-08-19, from [FAIL-0004](failures/FAIL-0004.md).**

`just test` = `lint compile batch test-ert`, unchanged. It is referenced in `README.org`,
`AGENTS.md` and muscle memory; silently widening it would make existing documentation wrong
and surprise the operator.

Instead `.githooks/pre-commit` was pointed at `just are-verify full`, which is a superset.
Same protection, no redefinition of an existing name.

## D-005 — Package versions are not reproducible, and that is accepted

**2026-08-19.**

`elpaca` installs from upstream `HEAD`. `just lock` / `just update` write
`var/elpaca-lock.el`, which `.gitignore:44` (`/var/`) excludes; no lockfile exists on this
machine. So two checkouts will not agree on package versions, and `just clean && just run`
can produce a different configuration from the one that was working.

This is the operator's existing choice, and committing a lockfile is a real trade (pinned
reproducibility vs. staying current on 197 packages) that ARE should not make unilaterally.
Recorded so that "the config broke and nothing in git changed" is diagnosed in seconds rather
than hours: check whether packages moved.

## D-006 — Two `.gitignore` inconsistencies are documented, not fixed

**2026-08-19.**

`.gitignore:23-24` ignores `AGENTS.md` and `CONVENTIONS.md`. `AGENTS.md` is tracked anyway,
so the rule is inert for it — but it means a *new* file named `CONVENTIONS.md` (which
`AGENTS.md` itself tells you to maintain, under "Documentation") would silently never be
committable.

Not changed: the ignore lines may be deliberate, and editing `.gitignore` during a bootstrap
whose job is to *add* files is how you accidentally commit something. Documented in
[../knowledge/SECRETS_AND_SENSITIVE_DATA.md](../knowledge/SECRETS_AND_SENSITIVE_DATA.md) §4,
and `are-audit` now verifies every ARE-created path is committable.

**Third instance, 2026-08-19 (same day):** the operator asked for the findings summary in
`docs/`, which `.gitignore:53` (`docs/*`) excludes wholesale — so `docs/ARE-FINDINGS.md` is
written but untrackable. Reported in that file as finding 10 with the one-line exception
(`!docs/ARE-FINDINGS.md`) rather than applied, for the same reason as above.

The pattern is now three-for-three, which is what turned it from an observation into a check:
`are-audit`'s `are-files-committable` was extended to scan `docs/` alongside `.are/`,
`.claude/` and `scripts/`. **Before creating any file this repository is meant to keep, run
`git check-ignore -v --no-index <path>`** — and note the `--no-index`, per
[../memory/LESSONS.md](LESSONS.md) L-009.

## D-007 — `.are/generated/CURRENT_CONTEXT.md` is committed, not ignored

**2026-08-19.**

It is small (tens of lines), it is a useful record of what the previous session believed it
was touching, and — per D-006 and L-009 — adding a `.gitignore` rule for it is the kind of
thing that later swallows a file somebody needed. Regenerate with `just are-context` rather
than trusting its timestamp.

## D-008 — Findings about the operator's identity, infrastructure and workflow are reported, never acted on

**2026-08-19.**

Three bootstrap findings were left deliberately unfixed because the fix is a judgement call
that belongs to the operator, not a defect:

- the work email and Snowflake identifiers in `init-sql.el` on a public remote
  ([SECRETS_AND_SENSITIVE_DATA.md](../knowledge/SECRETS_AND_SENSITIVE_DATA.md) §2) — removal
  needs history rewriting and a rotation decision;
- which of the two checkouts is canonical ([FAIL-0001](failures/FAIL-0001.md));
- whether to accept a ~3-minute pre-commit hook ([FAIL-0005](failures/FAIL-0005.md)).

Each is reported with a concrete recommendation and the exact command. ARE's job was to make
them visible and keep them visible, which the audit now does on every run.

## D-009 — `rata-claude-loop-on-task-failure` defaults to `halt`, not `skip`

**2026-08-20.**

`skip` is what makes an unattended overnight run useful: one impossible task in a list of
twenty stops being a reason for the other nineteen not to run. It is still not the default,
because the failure mode of each choice is asymmetric. A wrong `halt` costs waiting time and
is obvious the moment you look. A wrong `skip` spends money and edits files across a whole
list while the reason the first task failed — a bad root, a missing tool, an unusable verify
command — applies to every one of them, and the run reports "3 done, 17 failed" only at the
end.

So: `halt` while you are watching, `skip` set deliberately for a run you will not watch.
`.are/knowledge/CLAUDE_LOOP.md` §4 says this in the operating notes. A single-task run halts
regardless — there is nothing to continue to.

## D-010 — The run budget assumes `total_cost_usd` is per invocation, and this is untested

**2026-08-20.**

`rata-claude-loop--add-cost` sums the `total_cost_usd` of every `result` event to price a task
and a run. That is right if the CLI reports the cost of the invocation and wrong if it reports
a session total, in which case a `--resume` retry double-counts. Nothing in `tests/` can
settle it: every test uses the stub CLI, which reports whatever the stub says.

The error is in the safe direction — an over-count halts a run early rather than overspending
— so the assumption ships, recorded here and in `.are/knowledge/CLAUDE_LOOP.md` §3, rather
than being hidden in a comment. Settle it by reading one real journal file: if a task's
`cost` is roughly the sum of its attempts' individual costs, the assumption holds.

## D-011 — Jira is a second view in Emacs, not a sync into `work_tasks.org`

**2026-08-25.**

The operator keeps work tasks by hand in `~/workspace/second-brain/org-roam/work_tasks.org`
and also has tickets in corporate Jira. The obvious-looking answer — mirror the tickets into
that file, keyed on an issue id — was rejected, and so was `org-jira`, on the operator's
instruction: no custom sync code to own.

`lisp/init-jira.el` therefore adds `jira.el` (MELPA `jira`, upstream
`unmonoqueteclea/jira.el`, v2.21.1) as a *separate* view: a `tabulated-list` of issues under
`SPC J j`, filterable by JQL, with status changes and worklogs. Nothing writes into the roam
tree. `E` in the issues buffer exports what is on screen to Org-mode when a one-off bridge is
wanted, and that stays a deliberate, manual act.

Why not a sync, for the record — because the next session will be tempted again:

- The file is under `~/workspace/second-brain/`, which `rules/SAFETY_RULES.md` puts
  off-limits to autonomous writes. A sync is a program whose whole purpose is to write there.
- Jira and the org file disagree about what a task *is*. The org headings carry quoted notes
  from colleagues, `#+begin_quote` briefs written for the claude-loop, and sub-checklists.
  A mirror either drops that or has to preserve it around an idempotent rewrite.
- `work_tasks.org` is one node in a `hastodo` agenda query with an `org-kanban` block that
  nothing refreshes automatically. A writer would have to keep that block honest too.

Two smaller choices inside the same decision:

- **Credentials are not configured in the module.** `jira-username` and `jira-token` are
  deliberately left unset, which is what makes `jira.el` fall back to `auth-source` — the
  mechanism `init-system.el` already established. `rata-jira-base-url` defaults to nil and is
  set in the gitignored `custom.el`, because the instance hostname is corporate identity on a
  public remote (`knowledge/SECRETS_AND_SENSITIVE_DATA.md` §2). The module loads inert until
  the operator sets it.
- **The Jira buffers get emacs state, not evil bindings.** Upstream says it does not support
  evil (issue #31), and its keymaps live in `tabulated-list-mode` and `magit-section-mode`
  children — the shadowing trap already documented for `*claude-loop*`. Re-binding its dozen
  keys with `evil-define-key*` would be a maintenance liability against a package on a
  monthly release cadence, so `evil-set-initial-state` puts the three modes in emacs state
  and the documented keys work as shipped. `C-z` returns to normal state.

Revisit if the operator starts wanting Jira tickets in the agenda view rather than in their
own buffer. That is the point where a sync earns its cost — and it should be reconsidered as
a *whole* problem then, not bolted on.

## D-012 — `custom.el` is Custom's scratch pad; `local.el` is yours

**2026-08-25.**

D-011 told the operator to hand-write `rata-jira-base-url` into `custom.el`. That was wrong,
and the reason is worth keeping because it is easy to repeat.

`custom.el` was tracked until `ef33237` (2026-03-28), where it was gitignored in the same
commit that ignored `/var/`, `/etc/`, `/elfeed-db/` and `/persp-confs/` — i.e. it was
classified as *generated state*, correctly. Its entire content at that point was
`'(package-selected-packages nil)` and an empty `custom-set-faces`. Custom rewrites the file
whenever anything is saved from `M-x customize`, so anything hand-written there is churn
waiting to be clobbered, and it is ignored precisely because it is disposable.

So the two jobs are now two files, both gitignored:

| File | Written by | Contains |
|---|---|---|
| `custom.el` | Custom, on save | faces, `safe-local-variable-values`, theme trust — do not hand-edit |
| `local.el` | the operator, by hand | per-machine values that must not reach a public remote |

`local.el` is loaded by `init.el` *after* `custom.el` (so a hand-written value wins over a
stale Custom one) and *before* the modules (so their `defvar`s see it — `defvar` and
`defcustom` both leave an already-bound value alone, which is what makes plain `setq` in
`local.el` work).

**The committed template is the point of the design.** `local.el.example` exists so that the
answer to "what does a fresh machine need?" is versioned rather than remembered. The
operator's actual complaint was not that the file was gitignored — it was not knowing what to
recreate. A gitignored file with no committed manifest has that failure mode built in.

Rejected alternatives, briefly:

- **A committed `local.el.gpg`.** Solves syncing outright and is safe on a public remote, but
  startup currently never touches GPG (`~/.authinfo.gpg` is read lazily — see
  `init-irc.el:75`), and it would have to be skipped under `noninteractive` or it hangs
  `just batch`, `test-ert` and CI on a passphrase prompt. A passphrase at every startup to
  avoid copying one file per machine is a bad trade.
- **A committed file keyed on `(system-name)`.** No GPG and no manual step, but it only works
  for values you are willing to publish, which is exactly what these are not.

The same commit moved the six Snowflake `defvar`s out of `lisp/init-sql.el`, which
`.are/knowledge/SECRETS_AND_SENSITIVE_DATA.md` §2 had recommended and recorded as unresolved.
`rata-sql-snowflake-uri` now signals a `user-error` naming the unset parameters instead of
building a URI from nils that would fail much later inside a Leiningen nREPL boot. The git
history still contains the values; erasing that is a separate, HIGH-risk job that has not been
approved.

## D-013 — The justfile is split with `import`, not `mod`: target names are a public API

**2026-09-03.**

The justfile had grown to ~300 lines mixing five unrelated concerns, and `install-deps`
assumed pacman on a machine that runs apt. Both were fixed at once: the recipes moved into
`just/*.just`, and `install-deps` became a dispatcher on `/etc/os-release`.

just offers two ways to split a file, and they are not interchangeable:

| | `import 'just/x.just'` | `mod x 'just/x.just'` |
|---|---|---|
| Namespace | flattened into the root | prefixed |
| Invocation | `just lint` | `just x::lint` |
| Root variables | visible in the imported recipes | not shared |

`mod` is the better-isolated design in the abstract and is wrong here. Every target name in
this repo is referenced from outside the justfile: `README.org`, `AGENTS.md`,
`.githooks/pre-commit`, `scripts/are-verify.sh`, `.github/workflows/ci.yml`, and the
operator's habits. `mod` would rename all 30 of them in one commit, for no gain — the
concerns are separated by *file* either way, which is the whole of what was asked for.

The split's own regression test is `just --summary`, diffed against the pre-split output:
30 recipes before, 33 after, the three new names being `check-deps`, `install-deps-arch`
and `install-deps-debian`. Nothing else moved. That diff is the proof the split changed
nothing, and it is worth re-running after any future move.

Two consequences to keep in mind:

- **Cross-file dependencies resolve normally.** `test: lint compile batch …` lives in
  `just/test.just` while `compile` and `batch` are in `just/emacs.just`. Flat means flat.
- **Root variables are shared, so they stay in the root.** `emacs_bin`, `init_dir`,
  `os_id`, `os_like` and the `trash_*` lists are defined once in `justfile` and are visible
  inside every imported recipe.

## D-014 — `install-deps` never adds a package repository or pipes a script into a shell

**2026-09-03.**

`install-deps-debian` cannot install `kubectl`, `hugo` or `terraform` on Ubuntu 22.04 from
apt — the first two have no candidate at all, and `terraform` only resolves on a machine
where someone already added HashiCorp's repository. The obvious fixes are to `add-apt-repository`,
drop a keyring into `/etc/apt/`, `snap install`, or `curl https://… | sh` (which is what
rustup's own documented install is).

None of those happen inside a recipe. They change *what the machine trusts*, and that is a
decision with a blast radius beyond this config — it is the same class of act as the entries
in `.are/rules/SAFETY_RULES.md` §2, even though a package repository is not literally listed
there. The recipe prints the exact command for each and exits successfully having done
everything else.

The corollary is that `install-deps` finishing cleanly does **not** mean every dependency is
present, on either distro. That is what `just check-deps` is for, and why it reports the
resolved path of each binary rather than a tick.

## D-015 — Evil stays live in the Jira buffers; jira.el's keys are mirrored under `,`

**2026-09-08.** Reverses the `evil-set-initial-state … 'emacs` approach argued for in L-017,
on operator instruction: *"I would like to keep using EVIL mode inside the jira buffer. If
there is any keybinding conflicts then we need to fix those."*

The mechanism L-017 describes is unchanged and still the reason something has to be done:
`jira-issues-mode` derives from `tabulated-list-mode`, `jira-detail-mode` from
`magit-section-mode`, and evil's normal state shadows their single-letter keys. What changed
is which cost is preferred. Emacs state costs two lines and never drifts, but it takes
`j`/`k`, `/`, and the `SPC` leader away inside those buffers — in a config whose stated first
principle is "vim-first", spending the editor's whole idiom to buy one package's keyset is
the wrong trade for the operator.

So: normal state, and jira.el's shadowed keys live under the local leader `,`.

Three properties keep the maintenance cost that L-017 warned about from landing:

1. **The mirror is by `lookup-key`, not by naming commands.** `rata-jira--mirror-args` reads
   the definition out of `jira-issues-mode-map` / `jira-detail-mode-map` /
   `jira-tempo-mode-map` at bind time. Most of jira.el's bindings are anonymous closures over
   private helpers, so there is no symbol to bind and copying the bodies would fork upstream.
   This config already does exactly this for dashboard (`init-evil.el`).
2. **The mirror is small, because evil-collection already covers the tablist half.** `j`/`k`,
   `/`, `q`, `g r`, and `m`/`u`/`U`/`t` marking all work in normal state untouched. Only
   jira.el's *own* keys are mirrored — 11 in the issue list, 13 in the detail buffer, 3 in
   tempo. Re-binding what already works would be the part that drifts.
3. **Drift is a red test, not a dead key.** `rata-test-jira-mirrored-keys-exist-upstream`
   checks both ends of every entry: the upstream key still resolves in jira.el's map, and the
   `,` suffix resolves to a command in a live buffer. An upstream rename fails the suite
   instead of silently dropping one leader key.

`RET` is the one key taken outside the leader map: in a read-only list `evil-ret` moves down
a line, and RET opening the thing at point is the convention everywhere else here.

Superseded: L-017's second bullet ("`evil-set-initial-state` is the cheap fix; re-binding is
the expensive one") is now a statement about a trade this repository has decided the other
way. Its diagnostic value — read the mode's ancestry, not the readme — is untouched.

## D-016 — The Jira list hides finished work by default, through `--jql=`, not `--status=`

**2026-09-08.** On operator instruction: the `*Jira Issues*` list is "what is on my plate",
so `CLOSED`, `DEPLOYED`, `DONE` and `REJECTED` are out of the default query alongside the
existing `assignee = currentUser()`.

jira.el offers no way to say this. `--status=` is a single equality
(`jira-issues.el:222`) and there is no negation argument at all, so the choice was between
patching upstream's transient and using the one argument that composes: `--jql=`. When it
is set, `jira-issues--refresh` emits `(JQL) AND <everything else>`
(`jira-issues.el:231-238`), so the exclusion survives whatever the operator toggles in the
query menu instead of being replaced by it.

The value reaches a menu that is never opened through the prefix's *default value* — the
same place `--myself` comes from. `jira-issues` does not invoke the transient; it calls
`tablist-revert`, and `jira-issues--refresh` reads `(transient-args 'jira-issues-menu)`,
for which transient falls back to the set, saved or default value of a prefix that was
never displayed (L-040).

Two shapes were available and the cheaper one was rejected:

- **Replacing `jira-issues--transient-default-value`** (an `oset` on the prefix prototype's
  `value` slot, or `:override`) would restate `--myself` and `jira-issues-default-type` in
  this repository, freezing today's upstream default into our config.
- **`:filter-return` advice** — what is used — composes on top of whatever upstream returns.
  An upstream change to the default set is inherited; the only thing this module asserts is
  the one clause it cares about.

Consequences accepted:

1. **The statuses are instance workflow names, and a wrong one is not a soft failure.** JQL
   matches them case-insensitively but rejects a name no status in the instance carries —
   the whole query 400s and the list is *empty*, not unfiltered. Hence
   `rata-jira-excluded-statuses` is a `defcustom` that can be trimmed in `local.el`, and nil
   restores jira.el's own query. The names are not secret (they are ordinary workflow
   vocabulary), so the default stays in the tracked file rather than moving to `local.el`.
2. **Advising a private function is a rename away from silence.** `advice-add` on a function
   that does not exist succeeds and does nothing, so the guard is
   `rata-test-jira-default-query-reaches-the-transient`, which asserts the end state —
   `transient-arg-value "--jql="` on the real prefix — rather than the advice's presence
   alone.
3. **`F` (a saved Jira filter) still ignores this**, by design: it replaces the JQL wholesale
   (`jira-issues.el:340`), and a server-side filter is the server's query, not ours.

Related: D-011 (Jira is a view, not a sync), L-038 (the page-size cap this narrowing also
relieves — a smaller result set is less likely to be truncated at 100), L-040.

## D-017 — Sprint moves go through jira.el's request layer with a full Agile URL; the board id lives in `local.el`

**2026-09-09.** On operator request: "move tasks from the backlog to a sprint", with the
clarification that the team board is a Scrum board carrying one sprint that is never
closed and is used as a kanban board. So the feature is "move into the active sprint",
and the operator's one condition was that the active sprint is shown so the move can be
confirmed.

**What was found.** jira.el (1b1a436, 2026-03-15) has no Agile API support at all — no
board or sprint listing, no move, no rank. The only path that mentions sprints,
`U`/`, u` on the Sprint field in the detail buffer, builds its candidates from a JQL
search over issues that already carry a sprint and sends the value as an `{id}` object,
so it cannot offer a fresh sprint and is not expected to work. Kanban "move to board"
is not applicable to this board type and was dropped rather than deferred.

**Decision.**

1. *Reuse `jira-api-call`; do not add a second HTTP layer or patch upstream.*
   `jira-api--url` passes an endpoint through untouched when it already starts with the
   base URL (jira-api.el:174), so `rata-jira-agile-url` builds `<base>/rest/agile/1.0/…`
   and every sprint call inherits jira.el's auth header, error logging and
   current-host switching. `rata-test-jira-agile-url-passes-through-jira-api` binds the
   assumption to upstream's code. request.el skips the parser on a 204, so the default
   `json-read` parser is safe for the move endpoints.
2. *The active sprint is the default and is labelled everywhere* — in the prompt, on
   its candidate, in the confirmation message. `rata-jira-open-sprints` puts it first
   and drops closed sprints even if the server sends them.
3. *`rata-jira-board-id` is a `local.el` value* (D-012): not a secret, but it names a
   team on a public remote. Unset, the first command asks once per session
   (`rata-jira-choose-board`) from the boards the instance lists.
4. *Synchronous calls.* The pickers need the answer before they can ask, a move is one
   small POST, and jira.el makes the same trade for its own menus (transitions are
   fetched synchronously when the change menu opens). Errors surface as a `user-error`
   in Jira's own words (`rata-jira-agile-error-message`).
5. *`, m` in both buffers*, as this module's own commands rather than a mirror entry:
   `rata-jira-sprint-keys` is shared by the list and detail maps, and the key test
   asserts it resolves in both.

**Not tested here.** Nothing in `tests/` reaches the instance. The first live use should
check: `, m a` names the expected sprint; `, m s` on one issue lands it on the board;
`, m b` takes it off again. The `POST backlog/issue` endpoint (without a board id) is the
one most likely to differ across Server/DC versions — if it 404s, the fix is
`backlog/<board-id>/issue`.

Related: D-011 (a view, not a sync — this is the one deliberate write-back besides
what jira.el already offers), D-015 (the `,` leader map), D-016 (`--jql=` narrowing).

## D-018 — The Jira list groups by sprint with `tabulated-list-groups`, and patches tablist only while grouped

**2026-09-10.** Operator request: the list of "my" issues does not say which are in a
sprint and which are in the backlog; show it, and group the sprint issues together and
everything else together.

1. *A column and a grouping, not a second query.* The Sprint custom field is already in
   jira.el's field table (`:sprints`) and in the detail view; the list gains a
   `:rata-sprint` column (this module's own entry in `jira-issues-fields`, with a
   formatter that survives the older Server/DC string form) and Emacs 30's
   `tabulated-list-groups`, set from `jira-issues-mode-hook`. A `--current-sprint` query
   would have shown the board *or* the backlog; the operator asked to see both, apart.
2. *Membership is "has a sprint that is not closed."* The field lists every sprint the
   issue has ever been in. Treating any non-empty value as "in a sprint" would have put
   the whole finished history on the board.
3. *Upstream's custom-field request is fixed by advice on `jira-table-field-parent`,
   plus a synchronous field fetch before a search when `jira-fields` is empty.* Without
   the second half, the very first `jira-issues` of a session has no Sprint data and the
   second does — a column that fills itself on refresh reads as flaky. The sync fetch
   costs one small GET once per session; `jira-api-get-basic-data` skips its own fetch
   when the list is already filled. *Amended the same day (FAIL-0017):* `jira-api-get-fields`
   itself is overridden, because on Server/DC it maps every field to `(NAME . nil)` — the
   `field` endpoint has `id` but no `key` there — and that nil had also been emptying the
   detail view's Sprint line and `, u` on Sprint since the package was installed.
4. *tablist is patched by `:around` advice guarded on `tabulated-list-groups`, not
   replaced or rebound.* Its `S`, `m`/`t`/`U` and regexp filters walk the buffer line by
   line and predate group headings. Three advices in `init-jira.el`, each a no-op in
   every ungrouped tablist buffer (pdf-tools, docker, …). Rebinding the keys in
   `jira-issues-mode-map` was rejected: evil-collection owns those bindings and the same
   commands are reached from the transient menus.
5. *`, m g` is list-only* (bound in the list's leader map, not in
   `rata-jira-sprint-keys`), and `rata-jira-group-by-sprint` is the default it starts
   from — a `defcustom`, not a `local.el` value, since it names nothing corporate.

**Not tested here.** The shape of the Sprint field on the instance (object vs. Java
toString) and the custom field's actual id are only seen live; both paths are unit-tested
on fixtures. First live check: `SPC J j` shows a `Board  [active]  (N)` heading on the
first open, not only after `, r`.

Related: D-011 (a view, not a sync), D-015 (evil stays live; evil-collection's tablist keys
are exactly what the guards protect), D-017 (the moves whose result these headings show).

## D-019 — Jira issues are imported into `work_tasks.org` one way, append-only, on demand

**2026-09-11.** Operator request: "sync new tasks from Jira into `work_tasks.org`", then
on being shown D-011: "only sync from Jira to org and never the other way around", with
the marker column and the link-heading command included.

D-011 stands. What it rejected was a *mirror*: idempotent rewrite of headings keyed on an
issue id, plus `org-jira`. Its reasons — headings carry hand-written notes, briefs and
sub-checklists; Jira and the file disagree about what a task is; the kanban block is
refreshed by nothing — all argue against rewriting, not against appending. So:

1. *One direction.* Jira → org. Nothing in the import PUTs anything; marking a heading
   DONE does not transition the ticket. The one write-back in the module is still only
   sprint membership (D-017).
2. *Append-only, keyed on a property.* Identity is `:JIRA: KEY`, never the title. An
   issue whose key the file already carries is skipped; an existing heading is never
   rewritten, re-titled or moved. `rata-test-jira-import-appends-new-issues-only` asserts
   the file after an import byte-for-byte against the fixture with the entries inserted
   and nothing else changed, and that a second import is a no-op.
3. *On demand, confirmed.* `, i` in the list or detail buffer, on the marked issues or the
   one at point, after a `y-or-n-p` that names the file. No timer.
4. *Only what does not go stale.* Key, summary, a link, a CREATED stamp in the capture
   template's shape. Status, type and assignee are deliberately not copied — a one-way
   import can never correct them.
5. *The kanban block is refreshed* after an import (`rata-jira-org-refresh-kanban`), the
   one D-011 concern that appending alone would not answer.

Two companions make the dedupe honest. The `Org` column marks issues the file already
has, read from disk and cached on mtime+size, so "new" is visible before anything is
written. `SPC J l` on an org heading sets the property (and tags, and saves) for the
headings written before Jira existed here — without it every such ticket would be
offered as new forever.

The file path is not corporate identity, so `rata-jira-org-file` defaults to
`work_tasks.org` under `rata-org-roam-dir` rather than living in `local.el`. Tests use a
fixture in `temporary-file-directory`; nothing under `~/workspace/second-brain/` is read
or written by `tests/`.

Related: D-011 (a view, not a sync — this narrows, it does not reverse), D-012 (why the
path is not in `local.el`), D-017 (the one write-back).

## D-020 — Task files are kept in state order by a stable sort and a boundary move, not by archiving

**2026-09-11.** Operator: the `*_tasks.org` files are flat `** TODO` lists that nothing
orders, so DONE headings sit wherever they were finished and appended captures and Jira
imports (D-019) land after them. Asked for "a good solution to order these tasks", then
"go ahead and implement this".

Chosen:

1. *`org-log-done` is `time`.* No task carried a `CLOSED` stamp, so there was nothing to
   order the finished block by. This is the one setting that makes "newest finished
   first" and a "done this week" review possible at all.
2. *A stable sort, `rata-org-sort-tasks` (`SPC o s`).* `org-sort-entries` with a custom
   key `(KEYWORD-INDEX . -CLOSED-SECONDS)`: open states in the file's own `#+SEQ_TODO`
   order, done states last, newest `CLOSED` first. `sort` is stable, so the hand order
   inside the open block is a first-class thing the sort preserves rather than
   destroys. From a task heading the siblings are sorted; from the parent, its children.
   Org's built-in `?o` key was not used: it is `(- 99 (± (length (member kw keywords))))`,
   which puts done keywords *first* under `<`, and has no secondary key.
3. *A move on the open/finished boundary only.* `org-after-todo-state-change-hook` moves
   a task that becomes done to the head of the finished block and one that is reopened to
   the end of the open block, in `hastodo` files only. It does **not** move on TODO → STRT:
   that would make every state key in the file a re-shuffle, and the open block's order is
   the operator's. The move is `org-move-subtree-down` with a signed count, because that
   function saves and reinstalls markers — an agenda line's `org-hd-marker` follows the
   entry, where a cut-and-paste would have left it pointing at whatever slid into the
   old place and made the next `t` in the agenda hit the wrong task.

Rejected: `org-archive-location "::* Done"` plus `C-c C-x C-s`. Zero code, but archived
trees are skipped by the agenda by default, which would empty the "Finished" group in the
`p` Project Dashboard, and every entry gains five `ARCHIVE_*` properties. Also rejected:
re-sorting the whole parent from the hook — heavier, moves point off the task, and
`org-sort-entries` does not reinstall markers.

The one-time sort of the existing files is the operator's to run (`SPC o s` on `* Tasks`);
`SAFETY_RULES.md` keeps `~/workspace/second-brain/` out of autonomous hands, and the
tests use a temp buffer in the shape of `work_tasks.org` instead.

Related: D-019 (the import that appends after the DONE block), L-043 (org's own `CLOSED`
stamp carries the locale day name, as the existing files already do).
