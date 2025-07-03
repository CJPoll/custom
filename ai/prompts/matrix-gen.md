THINK I have a file for which I want to generate regression tests: $ARGUMENTS

Do not generate any code. Do not generate any tests.

Generate for me a comprehensive test matrix for the module.
- Do not include performance tests.
- Do cover failure cases.
- Ensure every single code branch in the file is covered.

Correct output is formatted in this way:
- First is the full file name
- Then for each public function output should be formatted as:
  - First is the function name, including arity (e.g. `changeset/2`)
  - Second is a set of test cases with each test case as a separate entry in
    markdown format. Each entry is a separate list-item (e.g. `- [test-case description]`)
    Each test case has the following four elements nest under it as an ordered
    list:
    1. Test case description
    2. Inputs to the test case
    3. Expected outputs (return values, logs, raised exceptions, etc.)
    4. Whether this is `Happy Path`, `Validation`, `Error Handling`, `Control
       Flow Decisioning` or some other category of behavior testing

The test matrices are put in a directory called `ai-artifacts/test-matrices/`.
`ai-artifacts/test-matrices/` has a subdirectory with the same name as the file under test.
  - Any characters that cannot be used in a file name are converted to `---`
Within the subdirectory, there is a test-matrix file for each public function name
  - Any characters that cannot be used in a file name are converted to `---`
  - The table for the file under test is written to this test-matrix file

So if I'm testing a file at lib/lms/courses/course.ex and that has a public
`changeset/2` function and an `extra_stuff/3` function, I would exect the
following file structure:

-- Project Root
 |
 - `ai-artifacts/test-matrices/`
   |
   - `lib---lms--courses---course.ex`
     |
     - `changeset---2.md` (markdown file with test matrix for `changeset/2` function)
     |
     - `extra_stuff---3.md` (markdown file with test matrix for `extra_stuff/3` function)
