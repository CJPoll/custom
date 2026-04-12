---
name: kg:data
description: Data Graph usage. Use when cataloging external systems, datasets, fields, and data lineage — the structural metadata layer of where data physically lives and flows.
argument-hint: <system or dataset to catalog>
---

# Data Graph — Structure & Lineage

The Data Graph catalogs *what data exists, where it lives, and how it flows*.
It is a metadata catalog of data infrastructure — not the data itself.

## When to Use the Data Graph

- Cataloging a database, API, warehouse, or other data system
- Documenting tables, views, streams, or files within a system
- Recording column names, types, and descriptions
- Mapping data flow between datasets (ETL, CDC, replication)

## When NOT to Use the Data Graph

- Defining what types of business entities exist → use Ontology
- Recording what "Revenue" means as a business concept → use Governance
- Storing facts about a specific customer → use Knowledge Graph

## Tools

### `create_data_graph`
Creates a workspace. Typically one per organizational scope.

```
name: "Production Infrastructure"
description: "All production data systems and their lineage"
```

### `create_external_system`
Creates a system with optional inline datasets and fields. This is the
primary workhorse — use inline datasets and fields to catalog an entire
system in one call.

```
name: "Salesforce"
data_graph_id: "<id>"
system_type: "CRM"
description: "Primary customer relationship management system"
datasets:
  - name: "accounts"
    dataset_type: "table"
    description: "Company/organization records"
    fields:
      - name: "id", data_type: "uuid", description: "Primary key"
      - name: "name", data_type: "string", description: "Account name"
      - name: "industry", data_type: "string", description: "Industry classification"
      - name: "annual_revenue", data_type: "float", description: "Annual revenue in USD"
  - name: "contacts"
    dataset_type: "table"
    description: "Individual contact records"
    fields:
      - name: "id", data_type: "uuid"
      - name: "account_id", data_type: "uuid", description: "FK to accounts"
      - name: "email", data_type: "string"
      - name: "full_name", data_type: "string"
```

### `create_lineage_edge`
Records data flow between two datasets. Directional: source → target
(data flows from source to target).

```
data_graph_id: "<id>"
source_dataset_id: "<salesforce accounts dataset id>"
target_dataset_id: "<snowflake dim_accounts dataset id>"
pipeline_name: "Fivetran Salesforce Sync"
transformation_type: "CDC"
description: "Real-time change data capture from Salesforce to Snowflake"
```

**Transformation types** (conventions, not enforced):
- `ETL` — Extract, transform, load (batch)
- `CDC` — Change data capture (real-time/near-real-time)
- `copy` — Direct replication, no transformation
- `aggregate` — Summarization or rollup
- `join` — Combines multiple sources
- `filter` — Subset of source data

### `list_data_graphs` / `describe_data_graph`
Discovery. List all graphs, then describe one to see all systems, datasets,
fields, and lineage edges.

## Best Practices

### System Modeling
- **Name systems by their canonical name**: "Salesforce", "Snowflake",
  "Internal PostgreSQL", not "CRM" or "DW".
- **Set system_type**: CRM, warehouse, database, API, file_storage, stream,
  message_queue. This helps categorize and filter.
- **One system entry per deployment**: If you have two PostgreSQL databases,
  create two external systems ("Orders PostgreSQL", "Users PostgreSQL").

### Dataset Modeling
- **Name datasets by their actual name**: Use the real table name
  (`dim_accounts`), not a friendly name.
- **Set dataset_type**: table, view, stream, file, collection, endpoint.
- **Include key fields**: You don't need every column, but include:
  - Primary keys and foreign keys
  - Fields referenced by business terms or governance policies
  - Fields that appear in lineage transformations

### Field Modeling
- **Use the actual column name**: `annual_revenue`, not "Annual Revenue".
- **Set data_type to the physical type**: string, integer, float, boolean,
  date, uuid, timestamp, text, json.
- **Add descriptions for non-obvious fields**: Skip for `id` or `created_at`,
  but explain `arpu` or `ltv`.

### Lineage Modeling
- **Map the critical paths**: You don't need every ETL job. Focus on:
  - Source-of-truth flows (CRM → warehouse)
  - Reporting pipelines (warehouse → BI tool)
  - Compliance-sensitive flows (PII movement)
- **Name pipelines**: Use the actual pipeline/job name when known.
- **One edge per hop**: If data flows A → B → C, create two edges, not one.

### Connecting to Governance
After creating data assets, link them to business terms via term_mappings
in the Governance Graph:
```
# When creating a business term:
term_mappings:
  - target_id: "<field id for annual_revenue>", target_type: "field"
```

This is how you say "this field implements this business concept."

## Example: Cataloging a Data Pipeline

```
1. Create data graph: "Analytics Infrastructure"

2. Create external systems with inline datasets:
   a. "Salesforce" (CRM)
      - accounts (table): id, name, industry, annual_revenue
      - opportunities (table): id, account_id, amount, stage, close_date
   b. "Snowflake" (warehouse)
      - raw.salesforce_accounts (table): id, name, industry, revenue
      - raw.salesforce_opportunities (table): id, account_id, amount, stage
      - analytics.dim_accounts (view): account_id, name, total_revenue, opp_count
   c. "Looker" (BI)
      - revenue_dashboard (view): account_name, total_revenue, pipeline_value

3. Create lineage edges:
   - Salesforce.accounts → Snowflake.raw.salesforce_accounts (CDC, "Fivetran")
   - Salesforce.opportunities → Snowflake.raw.salesforce_opportunities (CDC, "Fivetran")
   - Snowflake.raw.salesforce_accounts → Snowflake.analytics.dim_accounts (aggregate, "dbt")
   - Snowflake.raw.salesforce_opportunities → Snowflake.analytics.dim_accounts (join, "dbt")
   - Snowflake.analytics.dim_accounts → Looker.revenue_dashboard (copy, "Looker PDT")
```
