# Org, blog and slides

Org lives under `SPC o`. Notes are org-roam nodes; the roam directory and the Hugo site directory are set by `rata-org-roam-dir` and `rata-hugo-dir`.

## Tasks

- org-agenda with org-super-agenda grouping.
- `SPC o s` sorts a task file into state order: open states first (in `#+SEQ_TODO` order), finished tasks last with the newest `CLOSED` first. Changing a task's state moves it across that boundary automatically in files tagged `hastodo`.

## Blog (`SPC o b`)

Posts are org-roam nodes carrying the `:blog:` filetag, exported to Hugo with ox-hugo. The `blog-post` roam capture template (key `b`) sets the tag and export file name.

- `SPC o b s` reports every post as `exported`, `stale` or `never`.
- `SPC o b p` starts the Hugo preview server and opens the browser once it is up.
- `SPC o b d` is the dialogic formatting for blog posts: a `#+begin_dialogue` block holding a `- Speaker :: text` list is exported as a conversation. `SPC o b d a` audits how much of each section is dialogue.

## Slides (`SPC o p`)

Decks are org-roam nodes with the `:presentation:` filetag, exported to reveal.js with org-re-reveal into a directory outside your notes. Create one with the `presentation` capture template (key `r`), or convert an existing note with `rata-reveal-add-header`. reveal.js assets come from a CDN by default; `rata-reveal-install-local` and `rata-reveal-toggle-root` switch to a local copy for offline presenting.
