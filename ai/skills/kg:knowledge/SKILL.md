---
name: kg:knowledge
description: Knowledge Graph usage. Use when recording business facts as nodes with property and relationship assertions — the instance layer of what the business actually knows, with provenance.
argument-hint: <entities or facts to record>
---

# Knowledge Graph — Instances & Assertions

The Knowledge Graph captures *what the business actually knows* — specific
business entities and facts about them, each with provenance tracking where
the information came from.

## When to Use the Knowledge Graph

- Recording a specific business entity (customer "Acme Corp", product "Widget Pro")
- Asserting facts about an entity ("Acme Corp has annual revenue of $2M")
- Recording relationships between entities ("Acme Corp purchased Widget Pro")
- Capturing facts from multiple sources with provenance tracking

## When NOT to Use the Knowledge Graph

- Defining what types of things exist → use Ontology
- Cataloging database tables or data systems → use Data Graph
- Defining what "Revenue" means as a concept → use Governance Graph

## Prerequisites

Before creating knowledge graph nodes, you need:
1. **An Ontology** with classes defined (nodes require a `class_id`)
2. **A Knowledge Base** linked to that ontology (via `ontology_graph_id`)

The ontology defines *what types of things can exist*. The knowledge graph
records *specific instances* of those types.

## Entity Hierarchy

```
KnowledgeBase (root — workspace, linked to an ontology)
  └── Node (instance of an ontology class: "Acme Corp")
        ├── PropertyAssertion ("annual_revenue" = "$2M", source: "Annual Report")
        └── RelationshipAssertion (--purchased--> "Widget Pro", source: "CRM")
```

## Tools

### `create_knowledge_base`
Creates a workspace. Link it to an ontology to define what types of nodes
can be created.

```
name: "Enterprise Knowledge"
description: "Business entities and facts across the organization"
ontology_graph_id: "<ontology graph id>"
```

### `create_node`
Creates a specific instance of an ontology class. Every node has a type
(class_id) and a human-readable label.

```
label: "Acme Corporation"
knowledge_base_id: "<id>"
class_id: "<Organization class id from ontology>"
description: "Fortune 500 manufacturing company, primary customer since 2019"
```

### `assert_property`
Asserts a scalar fact about a node. Every assertion requires provenance
(the `source` field).

```
node_id: "<Acme Corp node id>"
attribute_name: "annual_revenue"
value: "2000000"
source: "2025 Annual Report, p.42"
```

**Key points:**
- `attribute_name` should match an attribute defined on the node's ontology
  class (e.g., if the Organization class has an "annual_revenue" attribute)
- `value` is always a string — the ontology attribute's data_type defines
  how to interpret it
- `source` is provenance — be specific enough to verify the fact later
- Multiple assertions on the same attribute from different sources are
  allowed (conflicting facts coexist in v1)

### `assert_relationship`
Asserts a directed edge between two nodes. The relationship type must
exist in the ontology.

```
node_id: "<Acme Corp node id>"
relationship_type_id: "<purchased relationship type id from ontology>"
target_node_id: "<Widget Pro node id>"
source: "Salesforce CRM - Opportunity #12345, closed 2025-03-15"
```

**Key points:**
- Direction matters: the assertion goes FROM `node_id` TO `target_node_id`
- `relationship_type_id` must reference a relationship type from the ontology
- Both nodes must exist before creating the relationship assertion
- The source class of the relationship type should match the source node's
  class, and the target class should match the target node's class

### `list_knowledge_bases` / `describe_knowledge_base`
Discovery. List all knowledge bases, then describe one to see all nodes
with their property and relationship assertions.

## Best Practices

### Node Design
- **Labels are human-readable identifiers**: "Acme Corporation", not
  "acme_corp" or "Organization #42".
- **One node per real-world entity**: Don't create multiple nodes for the
  same entity. If you learn more about an entity, add assertions to the
  existing node.
- **Add descriptions for context**: The label identifies; the description
  provides additional context that doesn't fit as a formal assertion.

### Property Assertions
- **Use ontology attribute names**: If the ontology class defines
  "annual_revenue", use that exact name. This enables validation and
  structured queries.
- **Values are strings**: Store numbers as strings ("2000000"), dates as
  ISO 8601 ("2025-03-15"), booleans as "true"/"false".
- **Be specific with sources**: The source should be precise enough that
  someone could go verify the fact:
  - "2025 Annual Report, p.42" (not "Annual Report")
  - "Salesforce CRM - Account Record, last updated 2025-03" (not "CRM")
  - "Manual Entry by @cjpoll, 2026-04-11" (for human-entered facts)
  - "Claude Code analysis of codebase, 2026-04-11" (for AI-derived facts)

### Relationship Assertions
- **Follow ontology direction**: If the ontology says Person --works_for-->
  Organization, assert from the Person node to the Organization node.
- **One assertion per relationship**: "Acme purchased Widget Pro" is one
  assertion. If they purchased it twice, make two assertions with different
  sources or timestamps.
- **Source matters for edges too**: "Salesforce Opportunity #12345" is
  more useful than "CRM data".

### Provenance Strategy
Provenance is the most important differentiator of the Knowledge Graph.
Without it, you just have a database. With it, you have an auditable
record of organizational knowledge.

**Source naming conventions:**
- System sources: "{System Name} - {Record Type}, {qualifier}"
  Example: "Salesforce CRM - Account Record, Q1 2025 export"
- Document sources: "{Document Title}, {page/section}"
  Example: "2025 Annual Report, p.42"
- Human sources: "Manual Entry by {person}, {date}"
  Example: "Manual Entry by @cjpoll, 2026-04-11"
- Derived sources: "{Method} from {input source}, {date}"
  Example: "Calculated from Q1-Q4 revenue reports, 2025-12-31"
- AI sources: "{Agent/Tool} analysis of {input}, {date}"
  Example: "Claude Code analysis of codebase, 2026-04-11"

### Handling Conflicts
In v1, conflicting assertions coexist. If Salesforce says revenue is $2M
and the Annual Report says $2.1M, both assertions are stored. This is by
design — trust hierarchies and resolution come later.

**Do:**
- Assert both values with accurate sources
- Let consumers decide which source to trust

**Don't:**
- Delete one assertion in favor of another (unless it's factually wrong)
- Try to resolve conflicts by averaging or choosing

### Retraction
To retract a fact, use `delete_entity` with entity_type
"property_assertion" or "relationship_assertion". This soft-deletes the
assertion, preserving the audit trail.

## Cross-Graph References

- **Knowledge → Ontology**: Every node references a class_id. Every
  relationship assertion references a relationship_type_id. The knowledge
  base itself can link to an ontology_graph_id.
- **Knowledge → Governance**: Nodes may implicitly relate to business terms.
  The UI resolves these via the node_detail enrichment layer.
- **Governance → Knowledge**: Term mappings can theoretically target node
  IDs, linking governed terms to specific knowledge instances.

## Workflow

```
1. Create ontology with classes and relationship types (if not done)
2. Create knowledge base linked to that ontology
3. Create nodes for business entities (label + class_id)
4. Assert properties on nodes (attribute_name + value + source)
5. Assert relationships between nodes (relationship_type_id + target + source)
6. As new information arrives, add more assertions to existing nodes
```

## Example: Recording Customer Knowledge

```
Prerequisites:
  Ontology with: Organization (legal_name, annual_revenue, industry, is_public)
                 Person (full_name, email, title)
                 Product (name, sku, category)
                 works_for: Person → Organization (many-to-one)
                 purchased: Organization → Product (many-to-many)

1. Create knowledge base: "Customer Intelligence"
   ontology_graph_id: "<enterprise ontology id>"

2. Create nodes:
   a. "Acme Corporation" (Organization class)
   b. "Widget Pro" (Product class)
   c. "Jane Smith" (Person class)

3. Assert properties:
   a. Acme Corp:
      - legal_name = "Acme Corporation Inc."
        source: "SEC Filing 10-K, 2025"
      - annual_revenue = "2000000"
        source: "2025 Annual Report, p.12"
      - annual_revenue = "2100000"
        source: "Salesforce CRM - Account Record"
        (Note: conflicting values coexist — different sources)
      - industry = "Manufacturing"
        source: "Company website, About page"
      - is_public = "true"
        source: "SEC EDGAR database"

   b. Widget Pro:
      - name = "Widget Pro"
        source: "Product catalog, 2025 edition"
      - sku = "WP-2025-001"
        source: "Internal inventory system"
      - category = "Hardware"
        source: "Product catalog, 2025 edition"

   c. Jane Smith:
      - full_name = "Jane Smith"
        source: "LinkedIn profile, accessed 2026-03"
      - email = "jane.smith@acme.com"
        source: "Salesforce CRM - Contact Record"
      - title = "VP of Engineering"
        source: "LinkedIn profile, accessed 2026-03"

4. Assert relationships:
   - Jane Smith --works_for--> Acme Corp
     source: "LinkedIn profile, accessed 2026-03"
   - Acme Corp --purchased--> Widget Pro
     source: "Salesforce CRM - Opportunity #12345, closed 2025-03-15"
```
