# pfront bug regressions

Each file in this directory is a regression case for a bug found while
building c89c. The test runner asserts each file produces **0 errors**.

When a new pfront bug is found, add the smallest failing case here, fix pfront,
then rebuild pfrontc and rerun. Never delete a case — they form the
growing correctness net.
