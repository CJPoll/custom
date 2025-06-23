I have a file under test for which I have defined test matrices for regression
tests: $ARGUMENTS

Ensure that tests for that file cover all cases in the test matrices.

If a test file already exists, add any generated tests to the file. If no such test file exists, then generate a new file for the tests.

For each matrix, look at each case separately; if any given case is covered by
existing tests, then there's no need to generate a test for that case from the
matrix. However, remaining cases still need to be generated from the matrix if
they are not covered by existing tests.

Do not make any changes to the existing code file - we are only generating regression tests to flag if we break current behavior.

If any of the generated tests fail, fix the tests by following the instructions
in @.claude/commands/fix-tests.md (`/fix-tests` custom command)
