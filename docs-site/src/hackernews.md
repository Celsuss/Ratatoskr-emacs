# Hacker News reader

Hacker News is read inside elfeed's own entry buffer. Opening an HN feed entry replaces its "Comments" stub with three sections: the story, a readable copy of the linked article, and the full comment thread. Other feeds are untouched.

`SPC a r h` opens an HN item by URL or id in a `*HN <id>*` buffer.

## Keys (in an HN entry)

| Key | Action |
|-----|--------|
| `za` `zc` `zo` `zM` `zR` | fold replies |
| `zj` `zk` `zu` | move by depth |
| `, c` | refetch |
| `, o` / `, O` | article / thread in the browser |
| `, y` | copy the permalink |

Threads over `rata-elfeed-hn-fold-threshold` comments open folded. Elfeed's own `]]`, `[[` and `TAB` keep working.

## Requirement

This needs elfeed's `main` branch (the config tracks it). If the hook it relies on is missing you get a warning when elfeed loads instead of a silently dead feature.
