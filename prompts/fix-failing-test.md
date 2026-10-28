<!-- Find the root cause of a failing test and fix it -->

A test is failing in {{project}}. Find the cause and fix it. If a specific
test is named below, start there.

Run the suite first and read the real failure. Find the command from the
justfile, Makefile or package manifest rather than guessing it, and narrow
to the failing test once you can.

Fix the cause, not the symptom. Before editing, say which case this is: the
test encodes the intended behaviour and the code is wrong, or the code is
right and the test's expectation is stale. Rewriting an assertion to match
what the code happens to do is only correct in the second case, and only
when you can say why the old expectation was wrong.

Keep the fix as small as the cause allows and in the style of the
surrounding code. Do not disable, skip or loosen a test to make the suite
pass; if that is the only way forward, stop and tell me why.

Re-run the suite afterwards and report the command you ran and its output,
including anything still failing.
