---
name: kg:governance
description: Governance Graph usage. Use when defining business terms, assigning stewardship, creating policies, classifying data, or mapping terms to data assets — the accountability and meaning layer.
argument-hint: <term, policy, or classification to define>
---

# Governance Graph — Meaning, Ownership & Policy

The Governance Graph defines *what data means, who is responsible for it,
and what rules apply*. It is the accountability layer that bridges technical
structure (Data Graph) and business knowledge (Knowledge Graph).

## When to Use the Governance Graph

- Defining a canonical business term ("Revenue", "Churn Rate", "Active Customer")
- Assigning ownership/stewardship of data or terms
- Creating data policies (retention, access, encryption, quality rules)
- Classifying data assets (PII, PHI, confidential, public)
- Linking business terms to physical data assets (fields, datasets, systems)

## When NOT to Use the Governance Graph

- Defining what types of things exist → use Ontology (classes, attributes)
- Recording specific business facts → use Knowledge Graph (nodes, assertions)
- Cataloging where data physically lives → use Data Graph (systems, datasets)

## Key Distinctions

- **Business Terms vs Ontology Classes**: A business term is a *definition*
  ("Revenue means total income from operations before deductions"). An
  ontology class is a *type* ("Organization has attributes: name, revenue").
- **Policies vs Ontology Constraints**: A policy says "customer data must be
  retained for 7 years" (operational rule). A constraint says "revenue must
  be non-negative" (data shape validation).
- **Classifications vs Ontology Taxonomies**: A classification is a flat
  governance label (PII, confidential). A taxonomy is a hierarchical
  controlled vocabulary (Industry > Technology > SaaS).

## Entity Hierarchy

```
GovernanceGraph (root — workspace)
  ├── BusinessTerm ("Revenue", "Churn Rate")
  │     ├── Stewardship (data_owner: "Jane Doe")
  │     └── TermMapping (links to Data Graph: field, dataset, or system)
  ├── Classification (PII label on a specific data asset)
  └── Policy (retention, access, encryption, quality rules)
```

## Tools

### `create_governance_graph`
Creates a workspace. Typically one per organization or major domain.

```
name: "Enterprise Data Governance"
description: "Canonical business terms, data ownership, and compliance policies"
```

### `create_business_term`
Creates a term with optional inline stewardships and term mappings. This is
the primary workhorse — define a term, assign owners, and link to data
assets in one call.

```
name: "Annual Revenue"
governance_graph_id: "<id>"
definition: "Total income from all business operations within a fiscal year, before deductions for expenses, taxes, or other costs. Reported in USD."
domain: "Finance"
stewardships:
  - steward_name: "Jane Doe"
    role: "data_owner"
    contact: "jane.doe@company.com"
  - steward_name: "Finance Analytics Team"
    role: "steward"
    contact: "#finance-analytics (Slack)"
term_mappings:
  - target_id: "<field id for annual_revenue in Salesforce>"
    target_type: "field"
  - target_id: "<field id for total_revenue in Snowflake>"
    target_type: "field"
```

**Stewardship roles** (conventions, not enforced):
- `data_owner` — Accountable for the data; makes decisions about access and quality
- `steward` — Day-to-day responsibility for data quality and maintenance
- `domain_expert` — Subject matter expert who can answer questions about meaning
- `technical_owner` — Responsible for the technical pipeline/infrastructure

**Term mapping target_type** values:
- `external_system` — Links term to an entire system
- `dataset` — Links term to a specific table/view/stream
- `field` — Links term to a specific column (most precise, preferred)

### `create_policy`
Creates a governance policy. Can target a specific Data Graph asset or
apply globally (omit target_id and target_type).

```
name: "PII Retention - 7 Years"
governance_graph_id: "<id>"
policy_type: "retention"
description: "All PII must be retained for 7 years per regulatory requirements. After 7 years, PII must be purged or anonymized."
target_id: "<dataset id>"
target_type: "dataset"
```

**Policy types**: retention, access, encryption, quality, security

### `list_governance_graphs` / `describe_governance_graph`
Discovery. List all graphs, then describe one to see all business terms
(with stewardships and mappings), classifications, and policies.

## Best Practices

### Business Term Design
- **Write precise definitions**: "Revenue" is ambiguous. "Total income from
  all business operations within a fiscal year, before deductions" is not.
- **Name in business language**: Use Title Case — "Annual Revenue", not
  "annual_revenue" (that's a field name for the Data Graph).
- **Set the domain**: Finance, Marketing, Sales, Operations, Engineering, HR.
- **One term per concept**: Don't combine "Revenue" and "Profit" into one term.

### Stewardship
- **Always assign a data_owner**: Every business term should have at least
  one person or team accountable for it.
- **Use real names and contact info**: The point of stewardship is knowing
  *who to ask*. "Finance Team" with no contact is not useful.
- **Multiple stewards are fine**: A term can have an owner, a steward, and
  a domain expert simultaneously.

### Term Mappings
- **Map to the most specific level**: If a term maps to a specific field,
  use target_type "field" — not "dataset" or "external_system".
- **Map all implementations**: If "Revenue" appears in Salesforce AND
  Snowflake, map to both. This traces a concept across systems.
- **Create Data Graph assets first**: Term mappings reference asset IDs.
  The assets must exist before you can map to them.

### Policies
- **Be specific**: Include thresholds, regulatory references, enforcement.
- **Target when possible**: A policy on a specific dataset is more
  actionable than a blanket policy.
- **Global policies are OK**: Omit target_id/target_type for org-wide rules.

## Cross-Graph Linking

The Governance Graph is the primary bridge:

- **Governance → Data** (term_mappings): "this field implements this concept"
- **Governance → Data** (classifications): governance labels on data assets
- **Governance → Data** (policies): rules targeting data assets
- **Knowledge → Governance** (implicit): nodes may reference business term
  IDs in property assertions

## Workflow

```
1. Catalog data assets in Data Graph first
2. Create governance graph
3. Define business terms with precise definitions and domains
4. Assign stewards to each term
5. Map terms to data assets (field-level when possible)
6. Create classifications for sensitive data
7. Create policies for compliance requirements
```

## Example: Governing a Revenue Pipeline

```
1. Create governance graph: "Finance Data Governance"

2. Create business terms:
   a. "Annual Revenue"
      definition: "Total income from operations within a fiscal year..."
      domain: "Finance"
      stewardships: [Jane Doe (data_owner), Finance Analytics (steward)]
      term_mappings: [SF accounts.annual_revenue, Snowflake dim.total_revenue]

   b. "Customer Churn Rate"
      definition: "Percentage of customers who cancel or do not renew..."
      domain: "Finance"
      stewardships: [Revenue Ops (data_owner)]

3. Create classifications:
   - PII on Salesforce contacts.email (field)
   - Confidential on Snowflake fact_revenue (dataset)

4. Create policies:
   - "PII Encryption at Rest" (encryption, global)
   - "Financial Data Retention" (retention, target: fact_revenue)
```
