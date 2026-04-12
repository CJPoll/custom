---
name: kg:ontology
description: Active Ontology graph usage. Use when defining classes, attributes, relationship types, or taxonomies — the type system and vocabulary for the Knowledge Graph.
argument-hint: <domain or types to model>
---

# Active Ontology — Type System & Vocabulary

The Active Ontology defines *what types of things can exist* and *how they
relate*. It is the schema layer that the Knowledge Graph builds on. Define
your ontology before creating knowledge graph nodes.

## When to Use the Ontology

- Defining a new type of business entity (Person, Organization, Product)
- Specifying what attributes an entity type has (name, revenue, founded_year)
- Declaring valid relationship types between entity types (works_for, purchased)
- Creating controlled vocabularies for enumerated values (Industry, Region)

## When NOT to Use the Ontology

- Recording specific facts about a business entity → use Knowledge Graph
- Cataloging a database table or API → use Data Graph
- Defining what a business term means → use Governance Graph

## Tools

### `create_ontology_graph`
Creates a workspace. One per domain is typical.

```
name: "Enterprise Domain Model"
description: "Core business entity types and relationships"
```

### `create_class`
Creates a type definition with optional inline attributes.

```
name: "Organization"
ontology_graph_id: "<id>"
description: "A company, agency, or other organizational entity"
attributes:
  - name: "legal_name", data_type: "string", required: true
  - name: "founded_year", data_type: "integer"
  - name: "annual_revenue", data_type: "float"
  - name: "is_public", data_type: "boolean", default_value: "false"
  - name: "industry", data_type: "string"
  - name: "description", data_type: "text"
```

**Attribute data types**: string, integer, boolean, date, float, text

### `create_relationship_type`
Defines a valid edge type between two classes. Directional: source → target.

```
name: "works_for"
ontology_graph_id: "<id>"
source_class_id: "<Person class id>"
target_class_id: "<Organization class id>"
cardinality: "many-to-one"
description: "A person is employed by an organization"
```

**Cardinality options**: one-to-one, one-to-many, many-to-one, many-to-many

### `create_taxonomy`
Creates a controlled vocabulary with inline entries. Use for enumerated
values that constrain what the Knowledge Graph can express.

```
name: "Industry"
ontology_graph_id: "<id>"
description: "Industry classification for organizations"
entries:
  - name: "Technology", description: "Software, hardware, IT services"
  - name: "Healthcare", description: "Medical, pharmaceutical, biotech"
  - name: "Finance", description: "Banking, insurance, investments"
  - name: "Manufacturing", description: "Physical goods production"
```

### `list_ontology_graphs` / `describe_ontology`
Discovery. List all graphs, then describe one to see all its classes,
attributes, relationship types, and taxonomies.

## Best Practices

### Class Design
- **Name classes as singular nouns**: Person, not People. Organization, not Organizations.
- **Use PascalCase**: DataPipeline, not data_pipeline.
- **Keep classes focused**: A class should represent one concept. If it has
  attributes from two different domains, split it.
- **Mark required attributes**: If a node of this type doesn't make sense
  without a particular attribute, mark it `required: true`.

### Attribute Design
- **Use the narrowest data type**: `integer` for year, not `string`.
  `boolean` for flags, not `string`.
- **Use `text` for long-form**: `string` for short values (names, codes),
  `text` for descriptions or notes.
- **Consider taxonomy references**: If an attribute has a fixed set of valid
  values (status, industry, category), create a Taxonomy for it. The attribute
  on the class can be `string` type — the taxonomy provides the valid values
  as a reference, not as an enforcement mechanism (v1).

### Relationship Design
- **Name relationships as verbs**: works_for, purchased, manages, implements.
- **Use snake_case**: not camelCase or PascalCase.
- **Direction matters**: "Person works_for Organization" means the edge goes
  from Person to Organization. Choose the direction that reads naturally.
- **Set cardinality accurately**: A person works for one org (many-to-one).
  A person can have many skills (one-to-many via the person side).

### Taxonomy Design
- **Name taxonomies as category nouns**: Industry, Region, Priority, Status.
- **Keep entries flat for v1**: The data model supports hierarchy but start
  with a flat list.
- **Taxonomies are vocabulary, not instances**: "Technology" is a taxonomy
  entry. "Acme Corp" is a knowledge graph node.

### Evolution
- Adding new attributes or relationship types is always safe.
- Adding `required: true` to a new attribute won't retroactively validate
  existing nodes (v1).
- Renaming a class or attribute requires updating references manually.

## Example: Building an Enterprise Ontology

```
1. Create ontology graph: "Enterprise Domain Model"
2. Create classes:
   - Organization (legal_name, industry, annual_revenue, founded_year, is_public)
   - Person (full_name, email, title, department)
   - Product (name, sku, category, launch_date, price)
3. Create relationship types:
   - Person --works_for--> Organization (many-to-one)
   - Organization --manufactures--> Product (one-to-many)
   - Person --manages--> Product (one-to-many)
   - Organization --partners_with--> Organization (many-to-many)
4. Create taxonomies:
   - Industry: Technology, Healthcare, Finance, Manufacturing, Retail
   - Department: Engineering, Sales, Marketing, Operations, Finance, HR
   - ProductCategory: Software, Hardware, Service, Subscription
```
