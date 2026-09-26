# Mission state

You are `athena-captain-PT-902`, dispatched by the athena-admiral to fix
**PT-902 (Bug)**: "Invoice list crashes with `ArithmeticError` when an invoice
has no line items." You are in the worktree
`~/.local/worktrees/walt_ui/pt-902-empty-invoice`; dependencies are bootstrapped
and the suite is green on the current code.

You have already located the defect: `Billing.Invoices.total/1` calls
`Enum.sum/1` on `invoice.line_items`, which is `nil` for an invoice with no
lines. The fix is one line: default the list to `[]`. The module has an
existing test file, `test/billing/invoices_test.exs`, with no case for an empty
invoice.

Decide the ordered actions you take NEXT, through the commit.
