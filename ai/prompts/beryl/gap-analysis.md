# Gap Analysis

## Objective

Ensure the consistency and completeness of the spec files we created.

## Process

- Identify any inconsistencies between the specs
- Identify any gaps in specs surfaced by other specs

## Examples

### Inconsistencies Between Specs

#### Feature Description vs BDD Scenarios

**Problem:** Feature description states one behavior, scenarios describe another.

```
Feature Description:
  "As a user, I can press Enter to open the selected file"

BDD Scenario:
  When the user double-clicks on a file
  Then the file opens in the active pane
  (No scenario for Enter key behavior)
```

**Resolution:** Add a BDD scenario for Enter key selection, or update feature
description to match actual intended behavior.

---

#### Architecture vs UI Component Spec

**Problem:** Architecture diagram shows a component not defined in UI spec.

```
Architecture (mermaid):
  FuzzyFileDialog --> FileResultRow
  FuzzyFileDialog --> EmptyStateMessage  <-- Missing from UI spec

UI Spec (ui.yaml):
  components:
    - name: FuzzyFileDialog
    - name: FileResultRow
    # No EmptyStateMessage component defined
```

**Resolution:** Add `EmptyStateMessage` component to ui.yaml, or update
architecture to show empty state as a variant of an existing component.

---

#### UI Callbacks vs Architecture Sequence Diagram

**Problem:** UI spec defines a callback not shown in architecture flow.

```
UI Spec:
  - name: FileResultRow
    callbacks:
      - name: on_remove
        description: Called when user clicks remove button

Architecture Sequence Diagram:
  User->>FuzzyFileDialog: Click file
  FuzzyFileDialog->>BerylWindow: on_file_selected(path)
  # No sequence for on_remove callback
```

**Resolution:** Add remove flow to architecture, or remove unused callback from
UI spec.

---

#### BDD Scenarios vs Authorization Spec

**Problem:** BDD scenario assumes permission that isn't defined.

```
BDD Scenario:
  Given the user is a "viewer"
  When the user clicks "Delete Project"
  Then the button is disabled

Authorization Spec (authorization.yaml):
  roles:
    - name: admin
    - name: editor
    # No "viewer" role defined
```

**Resolution:** Add "viewer" role to authorization spec, or update BDD scenario
to use defined role names.

---

#### Test Matrix vs Feature Description

**Problem:** Test matrix tests dimensions not described in feature.

```
Feature Description:
  "URLs are validated before being added to context"

Test Matrix:
  dimensions:
    - name: url_scheme
      values: [https, http, ftp, mailto]  <-- ftp/mailto not mentioned
    - name: authentication_credentials      <-- Not mentioned in feature
      values: [present, absent]
```

**Resolution:** Update feature description to specify supported schemes and
credential handling, or remove test cases for undocumented behavior.

---

### Gaps Surfaced by Other Specs

#### BDD Scenario Surfaces Missing UI State

**Gap:** BDD scenario describes error condition with no corresponding UI variant.

```
BDD Scenario:
  Given the fuzzy file picker is open
  When the git repository is unavailable
  Then an error message is shown: "Could not load git files"

UI Spec:
  variants:
    - name: default
    - name: empty
    # No "error" variant for git failure
```

**Action Required:** Add error variant to FuzzyFileDialog in ui.yaml:
```yaml
- name: error
  description: Error state when file loading fails
  when_state:
    error: "present"
  appearance:
    - Error icon
    - Error message text
    - Retry button (optional)
```

---

#### Architecture State Machine Surfaces Missing BDD Scenarios

**Gap:** State machine shows states with no corresponding test scenarios.

```
Architecture State Machine:
  state Open {
    ShowingAll --> Filtering: User types
    Filtering --> ShowingAll: Clear search
    Filtering --> NoResults: No matches    <-- No BDD scenario
    NoResults --> Filtering: User types    <-- No BDD scenario
  }

BDD Scenarios:
  - Scenario: Filter files by typing
  - Scenario: Clear search to show all files
  # No scenario for transitioning from NoResults back to Filtering
```

**Action Required:** Add BDD scenario:
```gherkin
### Scenario: Resume filtering after no results

Given the fuzzy file picker shows "No matching files"
When the user modifies the search text
Then the results update based on the new filter
```

---

#### UI Component Callback Surfaces Missing Authorization Rule

**Gap:** UI component allows action that requires permission not specified.

```
UI Spec:
  - name: ProjectCard
    callbacks:
      - name: on_delete
        description: Called when delete button clicked

Authorization Spec:
  permissions:
    - name: project:read
    - name: project:update
    # No project:delete permission defined

  rules:
    # No rule grants delete capability
```

**Action Required:** Add permission and rule to authorization.yaml:
```yaml
permissions:
  - name: project:delete
    resource: project
    action: delete

rules:
  - id: admin-delete-project
    roles: [admin]
    permissions: [project:delete]
```

---

#### Test Matrix Surfaces Missing Feature Requirement

**Gap:** Test matrix edge case reveals undocumented requirement.

```
Test Matrix:
  - id: EC-003
    description: Very long URL (500+ chars) is handled
    expected_outcome: "true"
    priority: medium

Feature Description:
  "URLs are validated and added to context"
  # No mention of URL length limits or handling
```

**Action Required:** Update feature description:
```markdown
## Technical Requirements
- URLs up to 2048 characters are supported
- URLs exceeding the limit show a validation error
```

---

#### Authorization Rule Without Test Coverage

**Gap:** Authorization rule defined but no test case verifies it.

```
Authorization Spec:
  rules:
    - id: owner-edit-document
      roles: [owner]
      permissions: [document:update]
      conditions:
        - field: owner_id
          operator: equals
          value: current_user.id

Test Matrix:
  dimensions:
    - name: user_role
      values: [admin, editor, viewer]  # No "owner" role tested
  cases:
    # No test case for owner-edit-document rule
```

**Action Required:** Add test cases to test matrix:
```yaml
dimensions:
  - name: user_role
    values: [admin, editor, viewer, owner]

cases:
  - id: AUTH-001
    description: Owner can update their own document
    dimension_values:
      user_role: owner
      resource_ownership: owned
      action: update
    expected_outcome: allowed
    priority: critical

  - id: AUTH-002
    description: Owner cannot update another user's document
    dimension_values:
      user_role: owner
      resource_ownership: not_owned
      action: update
    expected_outcome: denied
    priority: critical
```

---

#### Authorization Condition Surfaces Missing Data Model Field

**Gap:** Authorization condition references field not in UI data model.

```
Authorization Spec:
  rules:
    - id: owner-edit
      permissions: [document:update]
      conditions:
        - field: owner_id
          operator: equals
          value: current_user.id

UI Spec:
  - name: DocumentCard
    data_model:
      name: Document
      fields:
        - name: title
          type: String
        - name: content
          type: String
        # No owner_id field
```

**Action Required:** Add owner_id to data model in ui.yaml:
```yaml
fields:
  - name: owner_id
    type: String
    description: ID of the user who owns this document
```

---

### Cross-Spec Consistency Checklist

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

### Architecture Bucket Validation

The architecture must organize code into four distinct buckets. Validate that:

- [ ] **UI/View Code**: All UI framework code (GTK, HTML/CSS/JS) is isolated in
      dedicated UI classes, not mixed with domain logic or side effects
- [ ] **Side Effects (Ports/Adapters)**: Database queries, filesystem operations,
      API calls, and external service interactions are isolated in adapter classes
- [ ] **Domain Logic**: Business rules are in side-effect-free classes that can
      be unit tested without mocking infrastructure
- [ ] **Orchestration**: Service objects/use cases coordinate between buckets
      without containing domain logic or direct side effects themselves

#### Architecture Bucket Violations

**Problem:** Domain logic mixed with side effects.

```
Architecture:
  class DocumentValidator {
    +validate(doc) Boolean
    -save_validation_result(result)  <-- Side effect in domain class
    -query_duplicate_titles()        <-- Side effect in domain class
  }
```

**Resolution:** Extract side effects to adapter, keep domain pure:
```
class DocumentValidator {
  +validate(doc, existing_titles) Boolean  <-- Pure domain logic
}

class DocumentRepository {
  +find_titles_by_user(user_id) Array      <-- Side effect adapter
  +save_validation_result(result)          <-- Side effect adapter
}

class ValidateDocumentUseCase {
  +call(doc)                               <-- Orchestration
    titles = @repository.find_titles_by_user(doc.user_id)
    result = @validator.validate(doc, titles)
    @repository.save_validation_result(result)
}
```

---

**Problem:** UI component directly performs side effects.

```
UI Spec:
  - name: SaveButton
    callbacks:
      - name: on_click
        description: Saves document to database  <-- UI doing side effects

Architecture:
  SaveButton ->>Database: INSERT document  <-- Direct DB access from UI
```

**Resolution:** UI emits intent, orchestration handles side effects:
```
UI Spec:
  - name: SaveButton
    callbacks:
      - name: on_save_requested
        description: Emits when user clicks save

Architecture:
  SaveButton ->> Orchestrator: on_save_requested(doc)
  Orchestrator ->> DocumentRepository: save(doc)
  DocumentRepository ->> Database: INSERT
```

---

**Problem:** Orchestration contains domain logic.

```
Architecture:
  class CreateDocumentUseCase {
    +call(attrs)
      if attrs.title.length > 100        <-- Domain logic in orchestration
        return error
      if @repo.title_exists?(attrs.title)
        return error
      @repo.create(attrs)
  }
```

**Resolution:** Move validation to domain layer:
```
class DocumentValidator {
  +validate(attrs, existing_titles) Result  <-- Domain logic here
}

class CreateDocumentUseCase {
  +call(attrs)                              <-- Pure orchestration
    existing = @repo.find_titles()
    result = @validator.validate(attrs, existing)
    return result if result.error?
    @repo.create(attrs)
}
```
