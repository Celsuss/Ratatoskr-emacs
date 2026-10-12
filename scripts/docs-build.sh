#!/usr/bin/env bash
# Build the documentation site (docs-site/) with mdBook.
#
# README.org is the single source for the install/commands/keybindings/agents/loop
# pages, and init.el + each module's header line for the module index, so the site
# is generated from them and the output is gitignored (docs-site/src/generated/).
# Hand-written pages live beside it in docs-site/src/. Usage: docs-build.sh [build|serve]
set -euo pipefail

cd "$(dirname "$0")/.."
mode="${1:-build}"
repo_url="https://github.com/Celsuss/Ratatoskr-emacs"
blob_url="$repo_url/blob/master"
out=docs-site/src/generated

for tool in pandoc mdbook; do
  command -v "$tool" >/dev/null || { echo "docs-build: '$tool' not found on PATH" >&2; exit 1; }
done

rm -rf "$out"
mkdir -p "$out"

# The logo has one source, the repo root; mdBook copies it to the site from here.
cp logo.png "$out/logo.png"

# README.org section title -> generated page. A title missing from README.org
# fails the build rather than silently dropping a page.
pagemap=$(cat <<'MAP'
Features	features
Dependencies	dependencies
Getting Started	getting-started
Commands	commands
Reliability (ARE)	are
Architecture	architecture
Keybindings	keybindings
Agents panel	agents
Claude Code Task Loop	claude-loop
Adding a New Module	adding-a-module
MAP
)

# Split on top-level "** " headings; promote every heading one level so each
# chunk's section is a level-1 heading. Lines inside #+begin_/#+end_ blocks are
# left alone.
awk -F'\t' -v dir="$out" -v pagemap="$pagemap" '
  BEGIN {
    n = split(pagemap, lines, "\n")
    for (i = 1; i <= n; i++) { split(lines[i], a, "\t"); map[a[1]] = a[2] }
  }
  /^#\+begin_/ { inblock = 1 }
  /^#\+end_/   { inblock = 0 }
  !inblock && /^\*\* / {
    title = substr($0, 4); file = ""
    if (title in map) { file = dir "/" map[title] ".org"; seen[title] = 1 }
  }
  file == "" { next }
  !inblock && /^\*+ / { sub(/^\*/, "") }
  { print > file }
  END {
    for (t in map) if (!(t in seen)) { print "docs-build: README.org has no section \"" t "\"" > "/dev/stderr"; bad = 1 }
    exit bad
  }
' README.org

for f in "$out"/*.org; do
  md="${f%.org}.md"
  pandoc -f org -t gfm --wrap=none "$f" -o "$md"
  rm "$f"
  # Repo-relative links (file:, .are/...) point at the repository, not the site.
  sed -E -i 's#\]\(((\.\./)*(\./)?[A-Za-z0-9_.][^):# ]*)\)#](__REPO__/\1)#g' "$md"
  sed -E -i 's#\]\(__REPO__/(https?:[^)]*|mailto:[^)]*)\)#](\1)#g' "$md"
  sed -i "s#__REPO__#$blob_url#g" "$md"
done

# Module index: load order from init.el, description from each module's header line
# ";;; init-x.el --- description". Cannot drift from the config.
{
  echo "# Module index"
  echo
  echo "Generated from \`init.el\`: modules load in this order, so a module may depend on any module above it."
  echo
  echo "| # | Module | Description |"
  echo "|--:|--------|-------------|"
  n=0
  while read -r mod; do
    n=$((n + 1))
    desc=$(sed -nE "s/^;;; ${mod}\.el --- (.*)$/\1/p" "lisp/$mod.el" | head -1)
    printf '| %d | [`%s`](%s/blob/master/lisp/%s.el) | %s |\n' "$n" "$mod" "$repo_url" "$mod" "${desc:--}"
  done < <(sed -nE "s/^\(rata-load-module '(init-[^) ]+)\).*/\1/p" init.el)
} > "$out/modules.md"

# Every page SUMMARY.md names must exist, or mdbook builds a book with dead entries.
missing=0
while read -r p; do
  [ -f "docs-site/src/$p" ] || { echo "docs-build: SUMMARY.md names missing page $p" >&2; missing=1; }
done < <(grep -oE '\]\([^)]+\.md\)' docs-site/src/SUMMARY.md | sed -E 's/^\]\((.*)\)$/\1/')
[ "$missing" -eq 0 ] || exit 1

case "$mode" in
  build) mdbook build docs-site ;;
  serve) mdbook serve docs-site --open ;;
  *) echo "usage: docs-build.sh [build|serve]" >&2; exit 2 ;;
esac
