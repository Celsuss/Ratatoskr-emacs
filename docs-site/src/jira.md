# Jira

An issue browser built on [jira.el](https://github.com/unmonoqueteclea/jira.el), under `SPC J`.

## Setup

- Set `rata-jira-base-url` in `local.el`. The hostname is not committed.
- The token is read from `~/.authinfo.gpg` through `auth-source`.

## Using it

- The default query shows open work: statuses in `rata-jira-excluded-statuses` are filtered out.
- Evil stays active in the Jira buffers. jira.el's own keys are mirrored under the local leader `,`.
- The list shows a Sprint column and groups by sprint (`, m g` toggles).
- `, m` moves the marked issues into a sprint; the active sprint is the default and is always named in the prompt.
- `, i` appends the marked issues to `work_tasks.org` as `TODO` entries with a `:JIRA:` property. It is one-way and append-only: existing entries are never rewritten and nothing is sent to Jira.
