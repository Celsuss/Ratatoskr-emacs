# Plan — Hacker News comments in elfeed (`init-elfeed-hn.el`)

Status: **implemented 2026-10-06** (phases 1–5 below), uncommitted. Draft v4 was
approved by the operator starting the `/goal` run. Where the build differs from the design
below, see "As built" at the end.
- v1 installed `thanhvg/emacs-hnreader`; rejected by the operator as poorly maintained.
- v2 wrote a standalone reader (own story list + thread view).
- v3, on the operator's question: **elfeed already is the story list**, so keep it and
  teach its entry view to show the thread. That drops v2's list buffer, its Firebase
  fetching and its global keys — roughly half the code.
- v4: an HN entry in elfeed shows only the word `Comments`; the story and the linked
  article are now rendered above the thread (design point 6, Phase 3).

Each `## Phase N` below is one unit of work, done in interactive Claude Code via `/goal`
(operator preference: not `rata-claude-loop`). A phase is closed by appending ` [done]`
to its heading, or ` [blocked: <reason>]` when it needs the operator. Nothing is
committed autonomously (SAFETY_RULES), so this file is the progress record.

## Goal

Open a Hacker News entry in elfeed and see **what it is about and what people say**, in
the same `*elfeed-entry*` buffer: the story (title, site, points, author, and a readable
copy of the linked article, or the post text for Ask/Show HN), then every comment,
nested, foldable, readable with vim keys. No second app, no browser, no new package.

**The problem today:** the `news.ycombinator.com/rss` feed's entry content is literally
`<a href="…item?id=N">Comments</a>` — HN hosts links, not articles, so elfeed has nothing
to show and the entry reads as one word. The hnrss feeds are barely better (article URL,
points, comment count). Showing what a thread is about means fetching the article.

## What exists (checked 2026-10-05)

- `feeds.org` has three HN feeds, all `:aggregator:`: `news.ycombinator.com/rss`
  (`:hn:`), `hnrss.org/best` (`:hn_best:`), `hnrss.org/frontpage?points=250` (`:hn_250:`).
- **Both feed formats carry the HN item URL in the entry content**:
  news.ycombinator.com puts `<a href="https://news.ycombinator.com/item?id=N">Comments</a>`
  in the description, hnrss writes `Comments URL: https://news.ycombinator.com/item?id=N`.
  So the item id can be read from what elfeed already stored, for either feed, with one
  regexp — no extra request to find it. (Ask HN entries also have it as `:link`.)
- elfeed has a clean extension point: `elfeed-show-refresh` runs
  `elfeed-show-update-hook` after drawing an entry. No advice on elfeed is needed.
- evil-collection already uses `]]`/`[[` (next/previous entry) and `TAB` (next link) in
  `elfeed-show-mode-map`, so comment keys must not take those.

## Data source

**Algolia HN API**, `https://hn.algolia.com/api/v1/items/<id>`: the story plus its whole
comment tree nested under `children`, in **one request** however big the thread
(verified live). Comment `text` is HTML. No auth, no key, nothing in `local.el` or
`~/.authinfo.gpg`. (Firebase, the official API, would need one request per comment.)

## Design

1. **New file `lisp/init-elfeed-hn.el`,** loaded right after `init-elfeed`. It extends
   elfeed rather than living inside `init-elfeed.el`, so the feed configuration stays
   short and the HN code is testable alone. Owns no package; built-in `url-retrieve`,
   `json-parse-buffer` and `shr` only.

2. **Which entries get comments.** `rata-elfeed-hn-item-id` (pure: entry content and
   link in, id or nil out) finds the item id. An entry with an id gets a thread; every
   other entry is untouched, so non-HN feeds pay nothing. `rata-elfeed-hn-auto` (default
   t) fetches on open; nil means only on `, c`.

3. **Fetching is async and stale-safe.** The hook draws a `Comments: loading…` line at
   the end of the buffer and fetches. When the reply arrives it renders only if the
   buffer is live and still shows the same entry under the same generation counter —
   `n`/`p` to another entry, or `g`, makes the reply a no-op (the claude-loop's `:epoch`
   idea, at reader size). A failure replaces the line with `Comments: fetch failed (…) —
   , c to retry`, never a signal from a callback. `rata-elfeed-hn--fetch-json` is the
   only function that touches the network, so tests swap in a fixture. Threads are
   cached per item for the session; `g` refetches.

4. **Parsing is pure.** `rata-elfeed-hn--thread-from-json` turns the JSON into plists:
   dead/deleted comments dropped (but a deleted comment with live replies kept as
   `[deleted]` so the replies keep their parent), children in order, a reply count per
   subtree. Fixtures under `tests/fixtures/hn/`, captured once from the live API by hand.

5. **Rendering, inside elfeed's own buffer.** After the article content: a rule, a
   `N comments · P points` header, then each comment as an author/age line and its text,
   indented two columns per depth with a depth-coloured `│` gutter. Comment HTML goes
   through `shr` (same renderer elfeed uses for the article), so links, `<i>`, `<code>`
   and `<pre>` render properly and **comment text is never interpreted as Org or Lisp**.
   Each comment's region carries `rata-elfeed-hn-depth` / `-id` text properties; that is
   what folding and navigation read. Threads over `rata-elfeed-hn-fold-threshold` (default 300) comments open with replies
   folded and top-level comments visible, so a huge thread draws fast and reads as a
   table of contents.

6. **The story replaces the bare "Comments" content.** For an HN entry, the feed's
   content (the useless `Comments` link, or hnrss's URL/points list) is replaced by a
   story block built from the same Algolia reply: title, domain, `P points · by A · age ·
   N comments`, and then the body:
   - **Ask/Show HN and text posts:** the story's own `text` from Algolia, through `shr`.
   - **Link posts:** a second async fetch of the article URL, reduced to its main text
     with Emacs's own reader view (`eww-readable-dom`, present in this Emacs 31.1 —
     the same thing eww's `R` does), rendered with `shr`. Only `text/html` replies are
     rendered, the body is capped (`rata-elfeed-hn-article-max-bytes`, default 2 MB),
     and anything else — a PDF, a paywall, a JS-only page, a timeout — degrades to the
     title and link line plus `article not fetched (reason) — , o to open`, with the
     comments still shown. A readability result under ~200 characters counts as a
     failure, because a cookie wall "succeeds" with one sentence.
   The article and the thread are independent fetches under the same generation guard,
   so whichever arrives first draws first. `rata-elfeed-hn-fetch-article` (default t)
   turns the article fetch off — it contacts the article's own site, the same as
   opening it in a browser would. Pure part: `rata-elfeed-hn--readable-text` (HTML
   string in, DOM or nil out), tested on saved fixture pages.

7. **Keys: evil's fold vocabulary**, in `elfeed-show-mode-map` normal state (via
   `evil-collection-define-key`, the pattern `init-elfeed.el` already uses there), plus
   mirrors under the local leader `,`:
   - `za` toggle the comment at point and its replies, `zc` / `zo` close / open,
     `zM` fold everything to top level, `zR` unfold all;
   - `zj` / `zk` next / previous comment at the same depth, `zu` parent comment;
   - `, c` fetch or refetch the thread, `, o` open the HN thread in the browser,
     `, y` copy the permalink of the comment at point.
   Folding is invisibility overlays over a comment's replies, computed from the depth
   properties — about 40 lines, no outline-mode or magit-section in elfeed's buffer.

8. **HN item links route here.** An entry on `browse-url-handlers` sends
   `news.ycombinator.com/item?id=N` (a link in a comment, in an org note) to
   `rata-elfeed-hn-open-item`, which shows the thread in a `*HN <id>*` buffer using the
   same renderer and keys. Toggle `rata-elfeed-hn-route-item-links` (default t).

9. **Leader key, one:** `SPC a r h` "HN thread by URL/id" (`rata-elfeed-hn-open-item`),
   under the existing `SPC a r` rss group, at top level (FAIL-0009).

Out of scope: login, voting, posting (no write API); points/comment-count columns in
the search list (possible later from hnrss's content); changing `feeds.org`; any timer.

## Phase 1 — Item id, fetch, parse (no UI) [done]

`rata-elfeed-hn-item-id`, `rata-elfeed-hn--fetch-json`, the generation guard, the
parser, fixtures. Tests first: the id comes out of a stored entry from each of the two
feed formats and an Ask HN link, and nil for a non-HN entry; parser order, depth,
dropped/kept deleted, counts; a stale reply is a no-op; a failed fetch is a message.
Verify: `just are-verify relevant`.

## Phase 2 — Comments in the elfeed entry buffer [done]

The `elfeed-show-update-hook` function and the renderer; module in `init.el`. Tests
first (fetch stubbed): showing a fixture HN entry through the real `elfeed-show-entry`
yields the article, then one block per live comment at the right indent; a non-HN entry
is byte-identical to before; a comment containing `[[elisp:(x)]]` and `<script>` renders
as inert text; switching entry before the reply arrives leaves the new entry clean.
Verify: `just are-verify relevant`.

## Phase 3 — The story and the article above the thread [done]

Design point 6. Tests first (both fetches stubbed): a fixture `Comments`-only entry
shows title, domain, points and the readable article text, and no longer the bare
`Comments` word; an Ask HN fixture shows its post text; a non-HTML reply, an oversized
reply, a too-short readability result and a failed fetch each degrade to the link line
with the reason while the comments still render; with `rata-elfeed-hn-fetch-article`
nil no article request is made. Fixture pages are saved HTML under
`tests/fixtures/hn/`, never fetched in tests. Verify: `just are-verify relevant`.

## Phase 4 — Folding, navigation, keys, routing [done]

Design points 7–9. Tests first: each key resolves to its command in normal state in
`elfeed-show-mode` and does not displace `]]`/`[[`/`TAB`; `za` hides exactly the
replies; `zj` skips nested replies; `zM` leaves only depth-0 visible; the threshold
opens folded; the item regexp matches `item?id=` (http/https, with/without `www`) and
nothing else; `SPC a r h` is live after init (add to
`rata-test-keybindings-live-after-init`). Verify: `just are-verify relevant`.

## Phase 5 — Docs and full verify [done]

AGENTS.md module entry + load-order line, `.are/knowledge/MODULES.md` row (MEDIUM,
integrations/network, same as `init-elfeed.el`), `hn.algolia.com` in
`knowledge/INTEGRATIONS.md`, a decision record ("HN comments extend elfeed; no HN
package") in `.are/memory/DECISIONS.md`. Verify: `just are-verify full`. Live fetching
from Algolia and from article sites is NOT TESTED until the operator opens an HN entry in the GUI.

## Running it

```text
/goal Implement plans/hackernews-reader.md phase by phase. Done when `grep -E '^## Phase' plans/hackernews-reader.md | grep -vcE '\[(done|blocked: .*)\]$'` prints 0 and the last message reports PASS/FAIL/NOT TESTED per area. Stop after 10 tries.
```

## As built (2026-10-06)

Differences from the design above, each for a reason found while building:

- **Item id (2):** matched on the *shape* each HN feed writes (`>Comments</a>`, `Comments
  URL:`), not on any item URL in the content — otherwise a blog post that links an HN
  discussion would have its article replaced by that thread.
- **Network (3):** the single network function is `rata-elfeed-hn--retrieve`;
  `--fetch-json` and `--fetch-article` are thin wrappers over it. The JSON fetch has no
  size cap (a few thousand comments is legitimately megabytes); only the article does.
- **Keys (7):** in a minor mode, `rata-elfeed-hn-thread-mode`, not in
  `elfeed-show-mode-map` — the entry buffer is reused for every entry and the same keys
  serve the `*HN <id>*` buffer. `, o` opens the **article** (the post's thread for a text
  post), matching the degraded line's "— , o to open"; `, O` opens the HN thread, which
  design point 7 had given to `, o`. Folding shows an ellipsis via the invisibility spec,
  and each comment header carries its reply count.
- **Story before the thread:** the story section first shows the entry's title and the
  article's domain with "loading…", then fills in points, author, age and count when the
  thread arrives. In a `*HN <id>*` buffer the article URL is only known from the thread,
  so the article fetch starts then.
- **Fetching uses curl** when it is on PATH, url.el otherwise. The design said built-in
  `url-retrieve`; on first use every article timed out, because this network hands out an
  IPv6 address it does not route and url.el, unlike curl, does not fall back to IPv4
  (FAIL-0024). Comments were unaffected only because hn.algolia.com has no AAAA record.
- **Found on the way:** `just compile` installed packages over the network at compile time
  and hung while elpa.gnu.org was down — FAIL-0023 closed, L-056, audit check
  `compile-installs-nothing`. A `let` of a not-yet-loaded package's variable is lexical —
  L-057.

NOT TESTED: the live Algolia API, real article sites, the GUI rendering (pixel filling,
faces, the gutter), and evil's fold keys in an interactive session. Open an HN entry in
elfeed to check them.

