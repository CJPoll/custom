---
name: kg
description: Knowledge Graph system overview. Use when deciding which graph to record information in, understanding the four-graph architecture, or planning cross-graph workflows. Routes to kg:ontology, kg:data, kg:governance, kg:knowledge for detailed usage.
argument-hint: <what you want to record or look up>
---

# Knowledge Graph System

The Knowledge Graph is a four-graph enterprise context layer. Each graph
captures a different facet of organizational understanding. They are
interconnected but have distinct responsibilities.

## Decision Guide: Which Graph?

Ask yourself what kind of information you're recording:

| Question | Graph | Skill |
|----------|-------|-------|
| What *types* of things exist? What vocabulary do we use? | Active Ontology | `/kg:ontology` |
| What data *physically exists* and where does it live? | Data Graph | `/kg:data` |
| What does this data *mean* and who is responsible? | Governance Graph | `/kg:governance` |
| What specific *facts* do we know about business entities? | Knowledge Graph | `/kg:knowledge` |

## The Four Graphs

### Active Ontology (schema layer)
**Defines types, attributes, relationships, and controlled vocabularies.**

- Classes: Person, Organization, Product, Metric
- Attribute Definitions: what properties a class has (name, type, required)
- Relationship Types: valid edges between classes (works_for, purchased)
- Taxonomies: enumerated valid values (Industry > Sub-Industry > Vertical)

This is the *type system*. Build it before populating the Knowledge Graph.

### Data Graph (structural layer)
**Catalogs where data physically lives and how it flows.**

- External Systems: Salesforce, Snowflake, PostgreSQL
- Datasets: tables, views, streams, files within systems
- Fields: columns/attributes within datasets, with data types
- Lineage Edges: how data flows from source to target datasets

This captures *metadata about infrastructure*, not the data itself.

### Governance Graph (accountability layer)
**Defines meaning, ownership, and policy.**

- Business Terms: canonical glossary ("Revenue", "Churn Rate")
- Stewardships: who owns/stewards a term or data asset
- Policies: retention, access, encryption, quality rules
- Term Mappings: links business terms to Data Graph assets

This bridges technical structure (Data Graph) and business meaning (Knowledge Graph).

### Knowledge Graph (instance layer)
**Captures what the business actually knows as facts with provenance.**

- Nodes: specific instances of ontology classes (customer "Acme Corp")
- Property Assertions: scalar facts with source ("revenue is $2M" from "Annual Report")
- Relationship Assertions: directed edges with source ("Acme purchased Widget Pro" from "CRM")

Every assertion carries provenance. Conflicting assertions from different sources coexist.

## Workflow Order

When building a new knowledge domain from scratch, follow this order:

1. **Ontology first** — Define classes, attributes, relationship types, taxonomies
2. **Data Graph** — Catalog the systems, datasets, and fields that hold data
3. **Governance Graph** — Define business terms, assign stewardship, create policies, map terms to data assets
4. **Knowledge Graph** — Create nodes and assert facts with provenance

You can add to any graph at any time, but ontology should exist before
creating knowledge graph nodes (nodes require a class_id).

## Cross-Graph Linking

The graphs reference each other by ID:

- **Knowledge Base -> Ontology**: A knowledge base can link to an ontology graph
  (via `ontology_graph_id` on creation). Nodes require a `class_id` from that ontology.
- **Governance -> Data**: Business terms link to data assets via `term_mappings`
  (target_type: external_system, dataset, or field; target_id: the asset's ID).
- **Governance -> Data**: Policies can target specific data assets
  (target_type + target_id on creation).
- **Knowledge -> Governance**: Nodes may reference business term IDs in assertions.
- **Knowledge -> Data**: Nodes may reference dataset/system IDs in assertions.

**Permissions**: Storing a cross-graph reference only requires write access to the
source graph. Resolving it requires read access to the target graph. Dangling
references are allowed.

## Best Practices

### Naming Conventions
- **Classes**: PascalCase singular nouns (Person, Organization, DataPipeline)
- **Relationship Types**: snake_case verbs (works_for, purchased, implements)
- **Taxonomies**: PascalCase descriptive names (Industry, Region, StatusCategory)
- **Business Terms**: Title Case business language (Annual Revenue, Customer Churn Rate)
- **External Systems**: Proper names (Salesforce, Snowflake, Internal PostgreSQL)

### Provenance
Always provide meaningful `source` values on assertions. These should identify
where the fact came from specifically enough to verify it later:
- "Salesforce CRM - Account Record" (not just "Salesforce")
- "2025 Annual Report, p.42" (not just "Annual Report")
- "Manual Entry by @cjpoll, 2026-04-11" (for human-entered facts)

### Granularity
- **One ontology per domain**: Don't mix unrelated domains in one ontology graph
- **One knowledge base per domain**: Align with the ontology it references
- **One data graph per scope**: Could be per-org, per-team, or per-project
- **One governance graph per scope**: Typically organization-wide

## Common Tools

### Discovery (read)
- `list_ontology_graphs` / `list_knowledge_bases` / `list_data_graphs` / `list_governance_graphs`
- `describe_ontology` / `describe_knowledge_base` / `describe_data_graph` / `describe_governance_graph`

### Mutation (write)
- `update_entity` — Update any entity by `entity_type` and `entity_id`
- `delete_entity` — Soft-delete any entity by `entity_type` and `entity_id`

### Health
- `ping` — Verify the MCP server is reachable

For detailed usage of each graph, use the specific skill:
`/kg:ontology`, `/kg:data`, `/kg:governance`, `/kg:knowledge`
