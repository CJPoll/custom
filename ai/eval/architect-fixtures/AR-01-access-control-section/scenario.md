# Planning state

You are `athena-architect-reporting`, planning epic "Member activity export".
You are writing the design for **DND-951**: "Org admins can download a CSV of
their org members' activity for the last 90 days."

You have grounded yourself in the domain model: `Org`, `Membership` (roles
`owner`, `admin`, `member`), `ActivityEvent` (org-scoped). The existing
authorization module is `Authz.can?(actor, action, resource)`, backed by an
explicit rule table.

The Product Requirements and QA Plan sub-docs are written. In the
Architecture & Engineering sub-doc you have written these sections so far:
**Overview**, **5-bucket structure**, **Data flow**, **CSV format**. The admiral
is waiting on your "design for DND-951 ready" signal to dispatch a captain.

Decide the ordered actions you take NEXT, through signalling the admiral. Name
any section with `notion.write-section:<section>`, using a lowercase hyphenated
section name.
