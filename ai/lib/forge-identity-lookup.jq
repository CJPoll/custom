# forge-identity-lookup.jq — one (host, namespace) against the validated
# entries (DND-1936; called by fid_lookup in ai/lib/forge-identity.sh).
# Input: the entries array from forge-identity.jq. Args: $h, $n.
# Output, one field per line:
#   FOUND, bot ("" when pending), token_file, refresh, source, pending
#   MISS, the namespace of an entry that differs only in case (or ""),
#         the number of entries on host $h
# The match is exact: host and namespace, case included.
(map(select(.host == $h and .namespace == $n)) | first) as $e
| if $e then
    "FOUND", ($e.bot // ""), $e.token_file, $e.refresh, $e.source, ($e.pending // "")
  else
    "MISS",
    (map(select(.host == $h and (.namespace | ascii_downcase) == ($n | ascii_downcase))) | first | .namespace // ""),
    (map(select(.host == $h)) | length | tostring)
  end
