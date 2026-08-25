#!/usr/bin/env bash
# Renumber the `symbol`, `:NNN` citations in the knowledge pages.
#
# `are-audit`'s knowledge-line-refs check reports these when they drift, which they do
# on any change that inserts a form above a cited one. Reporting was the whole fix
# until a session that added six defcustoms to init-claude-loop.el had to correct
# twenty-two of them by hand -- twice, because the first pass guessed at numbers that
# had themselves moved. Detection without a fixer just relocates the work.
#
# A citation is rewritten to the line where its symbol is *defined*. That is stricter
# than the audit needs (it only asks that the symbol appear on the cited line) and it is
# what the pages mean in every current case.
#
# Prints what it changed and exits non-zero if any symbol could not be resolved, so it
# is safe in a pipeline. Idempotent: a second run changes nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

page=".are/knowledge/CLAUDE_LOOP.md"
source_file="lisp/init-claude-loop.el"

[ -f "$page" ] || { echo "no such page: $page" >&2; exit 1; }
[ -f "$source_file" ] || { echo "no such source: $source_file" >&2; exit 1; }

PAGE="$page" SOURCE="$source_file" python3 - <<'PY'
import io, os, re, sys

page, src = os.environ["PAGE"], os.environ["SOURCE"]
lines = io.open(src, encoding="utf-8").read().split("\n")

DEF = re.compile(
    r'^\((?:defun|defmacro|defcustom|defconst|defvar|defsubst|cl-defun)\s+'
    r'([A-Za-z0-9_*/+<>=?!-]+)')
defline = {}
for n, line in enumerate(lines, 1):
    m = DEF.match(line)
    if m and m.group(1) not in defline:
        defline[m.group(1)] = n

# Deliberately the same regex the audit pairs with, so this fixes exactly what that
# reports -- including its non-greedy symbol/number pairing, applied per line as grep
# does. A row citing two symbols against two numbers cannot be paired reliably by
# either; write one anchor per row.
CITE = re.compile(r'`(rata-claude-loop[^`]*)`[^`]*?`:(\d+)`')

changed, unresolved = [], []
out = []
for line in io.open(page, encoding="utf-8").read().split("\n"):
    def repl(m):
        symbol, old = m.group(1), m.group(2)
        new = defline.get(symbol)
        if new is None:
            unresolved.append(symbol)
            return m.group(0)
        if str(new) != old:
            changed.append((symbol, old, new))
            return m.group(0).replace("`:%s`" % old, "`:%d`" % new)
        return m.group(0)
    out.append(CITE.sub(repl, line))

io.open(page, "w", encoding="utf-8").write("\n".join(out))

for symbol, old, new in changed:
    print("  %s :%s -> :%s" % (symbol, old, new))
print("%s: %d citation(s) renumbered" % (page, len(changed)))

if unresolved:
    for symbol in sorted(set(unresolved)):
        print("  UNRESOLVED: %s has no definition in %s" % (symbol, src),
              file=sys.stderr)
    sys.exit(1)
PY
