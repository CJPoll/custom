---
name: beryl:gap-analysis
description: Cross-spec consistency and gap analysis validating feature description, BDD scenarios, architecture, UI, authorization, and test matrices.
argument-hint: <feature context>
disable-model-invocation: true
---

# Gap Analysis

## Objective

Ensure the consistency and completeness of the spec files we created.

## Process

- Identify any inconsistencies between the specs
- Identify any gaps in specs surfaced by other specs

## Cross-Spec Consistency Checklist

Use this checklist when performing gap analysis:

- [ ] Every user story in feature description has at least one BDD scenario
- [ ] Every BDD scenario's Given/When/Then maps to defined UI states and actions
- [ ] Every UI component callback appears in at least one architecture sequence
- [ ] Every architecture state has a corresponding BDD scenario
- [ ] Every authorization role appears in at least one BDD scenario
- [ ] Every authorization rule has at least one test case in the test matrix
- [ ] Every test matrix dimension maps to a documented feature requirement
- [ ] Every UI component referenced in architecture exists in UI spec
- [ ] Every data model field used in authorization exists in UI spec

## Architecture Bucket Validation

The architecture must organize code into four distinct buckets. Validate that:

- [ ] **UI/View Code**: All UI framework code is isolated in dedicated UI classes, not mixed with domain logic or side effects
- [ ] **Side Effects (Ports/Adapters)**: Database queries, filesystem operations, API calls, and external service interactions are isolated in adapter classes
- [ ] **Domain Logic**: Business rules are in side-effect-free classes that can be unit tested without mocking infrastructure
- [ ] **Orchestration**: Service objects/use cases coordinate between buckets without containing domain logic or direct side effects themselves

## Additional resources

For detailed examples of inconsistencies and gaps, see [examples.md](examples.md).
