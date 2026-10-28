<!-- Audit the whole repository for bugs and security risks -->

Audit {{project}} for bugs and security risks. Read the code before
judging it: start from the entry points and the files that handle input,
processes, credentials or the network, and follow what they call.

Look for:
1. Correctness bugs — wrong conditions, unhandled error paths, state that
   can go stale, resources that are never released.
2. Injection — anything built into a shell command, a query or a URL out of
   values the code did not choose itself.
3. Secrets — credentials, tokens or private hostnames written into tracked
   files, logged, or passed where they end up in a process listing.
4. Untrusted input treated as trusted — data from the network, from a file
   the repository does not own, or from another process.
5. Files and permissions — paths built from unvalidated input, world-readable
   writes, and destructive operations with no guard.

Report concrete findings with file and line, most serious first, each with
the input or state that triggers it and what goes wrong. Say plainly when
something is a risk you cannot confirm. Do not edit anything.
