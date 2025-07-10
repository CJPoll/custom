You've generated test matrices under @ai-artifacts/test-matrices/

For each file under that directory (including subdirectories), generate tests
for the module under tests. Ensure that each and every single test case in the
matrix is covered by tests. 

If a test file already exists, add any generated tests to the file.
If no such test file exists, then generate a new file for the tests.

For each matrix, look at each case separately; if any given case is covered by
existing tests, then there's no need to generate a test for that case from the
matrix. However, remaining cases still need to be generated from the matrix if
they are not covered by existing tests.

Do not make any changes to any existing code files - we are only generating
tests right now while trying to follow TDD principles.
