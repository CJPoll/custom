THINK I have a file under test for which I have defined test matrices for regression
tests: $ARGUMENTS

IFF the file under test already exists, then these are regression tests.

IFF the file under test does not exist, then these tests are for TDD to guide
the implementation of the file under test.

Ensure that tests for that file cover all cases in the test matrices.

If a test file already exists, add any generated tests to the file. If no such test file exists, then generate a new file for the tests.

For each matrix, look at each case separately; if any given case is covered by
existing tests, then there's no need to generate a test for that case from the
matrix. However, remaining cases still need to be generated from the matrix if
they are not covered by existing tests.

Do not make any changes to any existing code files - we are only generating tests to validate behavior.

IFF these are regression tests for pre-existing code, then run `/fix-tests`.
