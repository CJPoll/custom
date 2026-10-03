# forge-identity.jq — validate and merge the two halves of the identity map
# (DND-1936; called by fid_load in ai/lib/forge-identity.sh). Pure: no I/O.
# Args: $pubtxt  the public map file's text (ai/config/forge-identities.json)
#       $ov      the private overlay's gitlab .identities value, or null
# Output: {ok:true, entries:[entry + {source}], n_pub, n_ov}
#      or {ok:false, error:"<what is wrong, naming the entry>"}
# Every value an entry carries is checked free of tabs and newlines, because
# fid_lookup reads the lookup result one field per line.

def re_host: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$";
def re_name: "^[A-Za-z0-9_][A-Za-z0-9_.-]*$";

def str_matching($re): type == "string" and test($re);

# entry_problem: null when the entry is valid, else what is wrong.
def entry_problem:
  if type != "object" then "is not an object"
  elif (.host | str_matching(re_host)) | not then "has no lower-case `host`"
  elif (.namespace | str_matching(re_name)) | not then "has no top-level `namespace` (no '/', no URL form)"
  elif .bot == null then
    (if (.pending | type) == "string" and (.pending | length) > 0 and ((.pending | test("[\\t\\n\\r]")) | not)
     then null else "has `bot: null` with no one-line `pending` reason" end)
  elif (.bot | str_matching(re_name)) | not then "has a `bot` that is not a GitLab username"
  else null end
  // (if (.token_file | str_matching("^(~/|/)[^\\t\\n\\r]+$")) | not then "has no `token_file` (~/... or absolute)"
      elif (.refresh == "self_rotate" or .refresh == "group_service_account") | not
        then "has a `refresh` other than self_rotate or group_service_account"
      else null end);

def checked($src; $list):
  if ($list | type) != "array" then {error: "\($src) identities is not an array"}
  else
    ([$list | to_entries[] | (.value | entry_problem) as $p | select($p != null)
      | "\($src) entry \(.key) \($p)"] | first) as $bad
    | if $bad then {error: $bad}
      else {entries: [$list[] | . + {source: $src}]} end
  end;

($pubtxt | try fromjson catch null) as $pub
| if ($pub | type) != "object" then {ok: false, error: "the public map is not a JSON object"}
  elif $pub.kind != "athena-forge-identities" then {ok: false, error: "the public map's kind is not athena-forge-identities"}
  elif $pub.schema != 1 then {ok: false, error: "the public map's schema is not 1"}
  else
    checked("public"; $pub.identities) as $p
    | (if $ov == null then {entries: []} else checked("overlay"; $ov) end) as $o
    | if $p.error then {ok: false, error: $p.error}
      elif $o.error then {ok: false, error: $o.error}
      else
        ($p.entries + $o.entries) as $all
        | ([$all | group_by([.host, (.namespace | ascii_downcase)])[] | select(length > 1)
            | "two entries claim \(.[0].host)/\(.[0].namespace) (case-insensitively; sources \(map(.source) | join(", ")))"] | first) as $dup
        | ([$all | map(select(.bot != null)) | group_by(.token_file)[]
            | select((map(.bot) | unique | length) > 1)
            | "bots \(map(.bot) | unique | join(", ")) share the token file \(.[0].token_file)"] | first) as $shared
        | if $dup then {ok: false, error: $dup}
          elif $shared then {ok: false, error: $shared}
          else {ok: true, entries: $all, n_pub: ($p.entries | length), n_ov: ($o.entries | length)} end
      end
  end
