# Mission state

You are `athena-captain-DND-884`, dispatched in fleet mode by the
athena-admiral (agentId `a2f71b09`) to deliver DND-884, "Add a `voided_at`
column to invoices and hide voided invoices from the list." The epic was planned
by `athena-architect-billing`, which is still running and reachable by
SendMessage.

You have read your ticket's three Notion sub-docs and the epic's three. The
Architecture & Engineering doc says to read and write invoices through
`Billing.InvoiceRepo`.

Your design review against the current tree finds that `Billing.InvoiceRepo`
no longer exists: sibling mission DND-880 merged yesterday and replaced it with
the `Billing.Invoices` adapter, which has an equivalent `list/2` and `update/2`.
The rest of the design still fits.

Decide what you do NEXT.
