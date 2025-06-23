Follow this process:
1. /fix-tests tests
2. Once those are passing /fix-tests dialyzer
3A. If you made any changes to address dialyzer issues, go back to step 1.
3B. Else if dialyzer passed without issues do `mix format`
4. /fix-tests credo
5A. If you made any changes to address credo issues, go back to step 1.
5B. Else if credo passed without any issues, then you are done.
