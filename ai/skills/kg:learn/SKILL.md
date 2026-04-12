---
name: kg:learn
description: Record knowledge from conversations, research, or documents into the Knowledge Graph system. Use when the user shares facts, decisions, or context that should be persisted. Determines which graph(s) to update and executes the writes.
argument-hint: <facts or context to record>
---

# Learn — Record Knowledge into the Graph System

This skill processes information and records it in the appropriate graph(s).
Use it when new facts, entities, data sources, business terms, or
relationships need to be persisted in the knowledge graph system.

## Process

When the user provides information to record:

### 1. Discover Existing State
Before writing anything, understand what already exists:
```
list_ontology_graphs     → what type systems are defined?
list_knowledge_bases     → what knowledge bases exist?
list_data_graphs         → what data catalogs exist?
list_governance_graphs   → what governance frameworks exist?
```

If relevant graphs exist, describe them to see their contents:
```
describe_ontology          → existing classes, attributes, relationships
describe_knowledge_base    → existing nodes and assertions
describe_data_graph        → existing systems, datasets, lineage
describe_governance_graph  → existing terms, policies, classifications
```

### 2. Classify the Information
Determine which graph(s) the information belongs in:

| Information Type | Graph | Example |
|-----------------|-------|---------|
| A new type of thing | Ontology | "We track customers and products" |
| Properties a type should have | Ontology | "Customers have a name and revenue" |
| How types relate | Ontology | "Customers purchase products" |
| Valid categories/enums | Ontology | "Industries: Tech, Finance, Healthcare" |
| A data system exists | Data Graph | "We use Salesforce and Snowflake" |
| Tables/fields in a system | Data Graph | "Salesforce has an accounts table" |
| Data flows between systems | Data Graph | "Salesforce syncs to Snowflake via Fivetran" |
| What a business concept means | Governance | "'Revenue' means total income before deductions" |
| Who owns data | Governance | "Finance team owns revenue data" |
| Data compliance rules | Governance | "PII must be encrypted at rest" |
| Specific facts about an entity | Knowledge | "Acme Corp has revenue of $2M" |
| Entity relationships | Knowledge | "Jane works for Acme" |

### 3. Ensure Prerequisites Exist
Follow the dependency order:

```
Ontology (types) ← must exist before →
  Knowledge Base (needs ontology for class_id) ← must exist before →
    Nodes (need class_id) ← must exist before →
      Assertions (need node_id)

Data Graph (systems) ← must exist before →
  Governance term_mappings (need asset IDs to link to)
```

If prerequisites are missing, create them first. Ask the user for
clarification only when necessary — use reasonable defaults when the
intent is clear.

### 4. Execute Writes
Make the MCP tool calls to record the information. Always:
- Use existing entities when they already exist (don't duplicate)
- Provide meaningful descriptions
- For knowledge assertions, always include a `source` value
- Report back what was created, with IDs for reference

### 5. Report Results
After recording, summarize:
- What was created in which graph(s)
- Any cross-graph links that were established
- Suggestions for additional information that could be recorded

## Source Attribution

When the user provides information directly in conversation, use a source
like:
```
"User conversation, {date}"
"User @{username}, {date}"
```

When the information comes from a document or system the user references:
```
"{Document name}, {section/page if available}"
"{System name} - {record type}"
```

## Handling Ambiguity

If it's unclear which graph information belongs in, ask. Common ambiguities:

- **"We have a customers table"** — Is this:
  - Data Graph? (cataloging the physical table) → Yes, if they're talking
    about their database schema
  - Ontology? (defining a Customer type) → Yes, if they're defining what
    a customer IS
  - Both? → Often yes. Create the ontology class AND catalog the table.

- **"Revenue is $2M"** — Is this:
  - Knowledge Graph? (asserting a fact about a specific entity) → Needs
    a node: WHO has $2M revenue?
  - Governance? (defining what revenue means) → Only if they're defining
    the term, not asserting a value

- **"Jane owns the revenue data"** — Is this:
  - Governance stewardship? → Yes, assign Jane as data_owner on the
    Revenue business term
  - Knowledge Graph? → Only if "ownership" is a formal relationship
    type in the ontology

## Example Session

User: "We use Salesforce for CRM and Snowflake as our warehouse. Our main
customer Acme Corp has $2M revenue. The finance team owns all revenue data."

Response plan:
1. **Data Graph**: Create external systems (Salesforce, Snowflake)
2. **Ontology**: Ensure Organization class exists with annual_revenue attribute
3. **Knowledge Graph**: Create "Acme Corporation" node, assert revenue
4. **Governance**: Create "Revenue" business term, assign Finance team as steward

Execution:
```
1. list_ontology_graphs → check if ontology exists
2. If no ontology:
   a. create_ontology_graph: "Enterprise Domain Model"
   b. create_class: "Organization" with annual_revenue attribute
3. create_data_graph: "Enterprise Data Infrastructure"
4. create_external_system: "Salesforce" (CRM)
5. create_external_system: "Snowflake" (warehouse)
6. create_knowledge_base: "Enterprise Knowledge" (linked to ontology)
7. create_node: "Acme Corporation" (Organization class)
8. assert_property: annual_revenue = "2000000", source: "User conversation, 2026-04-11"
9. create_governance_graph: "Enterprise Data Governance"
10. create_business_term: "Revenue"
    definition: "Financial metric tracking income"
    stewardship: Finance Team (data_owner)
```
