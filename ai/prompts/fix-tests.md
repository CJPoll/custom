I have issues that I want you to fix. Help me debug these issues.

If I have asked you to fix broken tests, then here is how you reproduce the issue:
    | To run tests for the entire application: `mix test --max-failures 1`
    | To run tests in a single test file: `mix test <file> --max-failures 1`
    |
    | It's important to always add the flag to test commands.
    | - If --max-failures isn't set or is set too high, we run the risk of filling up the ai context with unnecessary text.

If I have asked you to fix jest tests, then here is how you reproduce the issue:
    | To run tests for the entire application, from `apps/<app>/assets` run: `npm test --bail`
    | To run tests in a single test file, from `apps/<app>/assets` run: `npm test <file> --bail`

If I have asked you to fix linter issues, then here is how you reproduce the issue:
    | To run the linter for the entire application: `mix credo --strict`
    | To run the linter for a single file: `mix credo --strict <file>`
    |
    | It's important to always add the `--strict` flag.
    | - If `--strict` isn't set, then credo will not detect certain issues that are important for code health.

If I have asked you to fix dialyzer issues, then here is how you reproduce the issue:
    | To run dialyzer for the entire application: `mix dialyzer`
    | If I have asked you to address dialyzer issues and any request files are under the `test/` directory, run: `MIX_ENV=test mix dialyzer`
    | Dialyzer can not be run against just a single file.
    |  - However, you should still only try to fix a single issue at a time.
    |  - That single issue must always be the first issue in the output.

If I have asked you to fix compilation warnings, then here is how you reproduce the issue:
    | To see compilation warnings for the entire application: `mix clean && mix compile`
    | Compilation warnings can not be checked against just a single file.
    |  - However, you should still only try to fix a single issue at a time.
    |  - That single issue must always be the first issue in the output.

If I have not specified what kinds of issues to fix, assume tests by default.

Allow all commands to run to completion - DO NOT terminate or end them early. If a command doesn't give you output, you probably terminated or ended it early and need
to do it again without terminating it early.

Tests and Linting issues allow you to specify a particular file to run against. Dialyzer does not.

Here's the process to follow. DO NOT move to the next step until the current step is completed. DO NOT ignore compilation warnings; immediately address each one you see.
1. Run the tool for the application. If I have given you instructions to narrow down the scope, those instructions take precedence over this step's instructions.
2. When you see an issue in the output, fix only the first issue.
3. From then on, only run the single test that you are trying to fix if the tool supports doing so.
4. Once that singular issue is fixed, run the tool for the entire file.
5A. If there are any issues, go to step 2.
5B. Else if that file has no more issues, run the tool for the entire application.
6A. If you see issues, go back to step 2.
6B. Else if there are no remaining issues, you have successfully debugged the problem.
7. Run the formatter (`mix format`)

And now you're done - congratulations on debugging the application!
