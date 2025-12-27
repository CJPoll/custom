# authorization-spec

In @~/dev/beryl/lib/schemas/authorization.json, we define a json schema that this feature's authz.yaml (the path to which is
 in context) MUST conform to. In this feature's authz.yaml (the path to which is in context), define the spec for each authorization rule for interactions; this must conform to the JSON schema defined in ui_component.json as previously mentioned.

As a matter of security, assume that "the UI doesn't provide the option" is insufficient; assume a malicious actor can use the browser console to send arbitrary phoenix events up the channel, perfectly simulating legitimate UI behavior but with roles that shouldn't be able to do certain things.

$ARGUMENTS
