---
name: athena:format:test-matrix
description: Output format specification for test matrices organized by file and public function.
user-invocable: false
---

A test matrix is organized by file, then by public function, and each
function's test cases are rendered as a **markdown table** — one row per test
case.

## Structure

- **Per file** — a level-2 heading with the full file name:
  `## lib/my_app/accounts/user.ex`
- **Per public function** — a level-3 heading with the function name and arity:
  `### changeset/2`
- **Per function** — a single markdown table whose rows are the test cases.

## Table columns

| Column | Contents |
|---|---|
| `#` | Sequential number of the test case within the function (1, 2, 3, …). |
| `Test Case` | A short description of the behavior under test. |
| `Inputs` | The inputs to the case. List each input as `name: value`; separate multiple inputs with `<br>` so they stack within the cell. |
| `Expected Output` | The expected result — return value, emitted log, raised exception, side effect, etc. |
| `Category` | One of `Happy Path`, `Validation`, `Error Handling`, `Control Flow Decisioning`, or another named behavior category. |

## Example

```markdown
## lib/my_app/accounts/user.ex

### changeset/2

| # | Test Case | Inputs | Expected Output | Category |
|---|---|---|---|---|
| 1 | builds a valid changeset from complete attrs | user: `%User{}`<br>attrs: `%{name: "Ada", email: "ada@x.io"}` | `%Ecto.Changeset{valid?: true}` | Happy Path |
| 2 | rejects a missing email | user: `%User{}`<br>attrs: `%{name: "Ada"}` | `changeset.valid? == false`<br>error on `:email` — "can't be blank" | Validation |
| 3 | rejects a malformed email | user: `%User{}`<br>attrs: `%{email: "nope"}` | error on `:email` — "has invalid format" | Validation |

### verify_password/2

| # | Test Case | Inputs | Expected Output | Category |
|---|---|---|---|---|
| 1 | returns the user on a correct password | user: `%User{}`<br>password: `"correct"` | `{:ok, %User{}}` | Happy Path |
| 2 | returns an error on a wrong password | user: `%User{}`<br>password: `"wrong"` | `{:error, :invalid_credentials}` | Error Handling |
```

## Rules

- One table per public function; do not merge multiple functions into one table.
- Every test case is one row; keep the four content columns (`Test Case`,
  `Inputs`, `Expected Output`, `Category`) populated for every row.
- Keep prose out of the matrix — the table is the output. Any necessary caveat
  goes in a short line beneath the relevant table, not inside a cell.
