# Private work overlay

This directory holds work-domain values and work-only procedures for the Athena
harness. The public harness (`~/dev/custom`) names keys; the values live here.

It was created from the public skeleton
`~/dev/custom/ai/private-overlay/skeleton/` by
`scripts/setup-private-overlay --init`. The contract is
`~/dev/custom/ai/contracts/athena-private-overlay.md`.

## Rules

- **No credentials.** Tokens, keys and passwords never go here. They stay
  where they are today (`~/.claude/*token*`, `~/.config/athena-inbox-client/`,
  the GitHub App key). A credential found here is a defect to report.
- **Never pushed.** This is a local-only git repository with no remote. It is
  synced between the owner's machines over ssh.
- **Mode 0700, owned by you.** The resolver refuses a root with any group or
  other permission bits.
- **Commit every change.** The outbound scan's pattern floor is the committed
  `outbound/patterns.tsv`; an uncommitted edit can only add a pattern.

## Layout

| Path | What |
|---|---|
| `athena-overlay.json` | the marker: `{"kind": "athena-private-overlay", "schema": 1}` |
| `overlay/<file>.json` | values, read with `ai/bin/private-overlay get <file> <.key.path>` |
| `outbound/patterns.tsv` | the outbound scan's patterns, `<label><TAB><regex>` |
| `.claude-plugin/marketplace.json` | the local plugin marketplace `custom-work` |
| `plugins/work/` | the `work` plugin; its skills load as `work:<name>` |
