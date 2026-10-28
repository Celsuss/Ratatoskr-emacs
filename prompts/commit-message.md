<!-- Write a commit message for the staged change -->

Write a commit message for the change staged in {{project}}.

Read the change first: `git status` for what is staged, `git diff --staged`
for the change itself, and `git log -15` for the conventions this repository
actually follows — subject shape, how symbols are quoted, which trailers
every commit carries. Match that log rather than a generic convention.

The subject is one line, `type(scope): Imperative summary`. Say what the
commit does, not which files it touches.

The body explains why. State what was wrong or missing before, what the
change does about it, and anything load-bearing that a later reader would
otherwise undo — a non-obvious ordering, a constraint imposed by an upstream
package, an approach that was tried and does not work. Omit the body only
when the subject is genuinely the whole story.

Leave out what the diff already says: no file-by-file list, no restating a
rename, no roll-call of test names. Mention a test only when it pins
something the next reader needs to know is pinned.

Show me the message. Do not commit unless I say so.
