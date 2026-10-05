# frozen_string_literal: true

# Domain tests for ai/lib/forge_push_scan.rb (DND-2023). Run by
# ai/test/forge-push-scan/self-test.sh; prints one "ok <name>" or
# "FAIL <name>" line per case.
require_relative "../../lib/forge_push_scan"

P = ForgePushScan

def t(name, cond)
  puts "#{cond ? 'ok' : 'FAIL'} #{name}"
end

def raises
  yield
  false
rescue P::Unreadable
  true
end

a = "a" * 40
b = "b" * 40
s = P.parse_spec("+refs/heads/x:refs/heads/y")
t("spec: force, src, dst", s.force && s.src == "refs/heads/x" && s.dst == "refs/heads/y")
t("spec: delete has an empty src", P.parse_spec(":refs/heads/y").src.empty?)
m = P.parse_spec(":/secret commit:refs/tags/x")
t("spec: a :/<text> source splits at the last colon", m.src == ":/secret commit" && m.dst == "refs/tags/x")
t("spec: no colon is unreadable", raises { P.parse_spec("refs/heads/x") })
t("spec: no destination is unreadable", raises { P.parse_spec("refs/heads/x:") })
refs = P.parse_list([":object-format sha1\n", "@refs/heads/main HEAD\n", "#{a} refs/heads/main\n", "? refs/heads/q\n"])
t("list: tips only", refs == { "refs/heads/main" => a })
u = P.update_for_spec(P.parse_spec("HEAD:refs/heads/main"), b, refs)
t("update: remote tip from the listing", u.remote_oid == a && u.local_oid == b && u.local_ref == "HEAD")
n = P.update_for_spec(P.parse_spec("HEAD:refs/heads/new"), b, refs)
t("update: a ref the listing does not name is zero", n.remote_oid == "0" * 40)
d = P.update_for_spec(P.parse_spec(":refs/heads/main"), nil, refs)
t("update: delete", d.local_ref == "(delete)" && d.local_oid == "0" * 40 && d.remote_oid == a)
t("update: a local that is not an object id is unreadable", raises { P.update_for_spec(P.parse_spec("x:refs/heads/y"), "nope", {}) })
c = P.parse_command("#{a} #{b} refs/heads/main\0report-status side-band-64k\n")
t("command: the first line, with capabilities", c.remote_oid == a && c.local_oid == b && c.remote_ref == "refs/heads/main")
t("command: shallow is skipped", P.parse_command("shallow #{a}\n") == :shallow)
t("command: push-cert is unreadable", raises { P.parse_command("push-cert\0caps\n") })
t("command: a non-command is unreadable", raises { P.parse_command("hello\n") })
t("pkt: flush, delim, data", P.pkt_header("0000") == [:flush] && P.pkt_header("0001") == [:delim] && P.pkt_header("0032") == [:data, 46])
t("pkt: a bad header is unreadable", raises { P.pkt_header("zz00") } && raises { P.pkt_header("0003") } && raises { P.pkt_header(nil) })
t("stdin: the hook's ref lines", P.pre_push_stdin([u]) == "HEAD #{b} refs/heads/main #{a}\n")
z = "0" * 40
t("advertised: the first line, with capabilities", P.parse_advertised("#{a} refs/heads/main\0report-status delete-refs\n") == [a, "refs/heads/main"])
t("advertised: a later line", P.parse_advertised("#{b} refs/tags/v1\n") == [b, "refs/tags/v1"])
t("advertised: an empty repository's capabilities line names no tip", P.parse_advertised("#{z} capabilities^{}\0report-status\n") == :skip)
t("advertised: version and shallow lines name no tip", P.parse_advertised("version 1\n") == :skip && P.parse_advertised("shallow #{a}\n") == :skip)
t("advertised: an ERR line is unreadable", raises { P.parse_advertised("ERR access denied\n") })
t("advertised: a non-ref line is unreadable", raises { P.parse_advertised("hello\n") })
t("listing: the scan's '<oid> <ref>' lines", P.listing_text({ "refs/heads/main" => a, "refs/tags/v1" => b }) == "#{a} refs/heads/main\n#{b} refs/tags/v1\n")
