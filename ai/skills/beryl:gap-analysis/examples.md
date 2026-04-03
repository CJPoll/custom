# Gap Analysis Examples

## Inconsistencies Between Specs

### Feature Description vs BDD Scenarios

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

### Architecture vs UI Component Spec

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

### UI Callbacks vs Architecture Sequence Diagram

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

### BDD Scenarios vs Authorization Spec

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

### Test Matrix vs Feature Description

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

## Gaps Surfaced by Other Specs

### BDD Scenario Surfaces Missing UI State

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

**Action Required:** Add error variant to FuzzyFileDialog in ui.yaml.

---

### Architecture State Machine Surfaces Missing BDD Scenarios

**Gap:** State machine shows states with no corresponding test scenarios.

```
Architecture State Machine:
  state Open {
    ShowingAll --> Filtering: User types
    Filtering --> ShowingAll: Clear search
    Filtering --> NoResults: No matches    <-- No BDD scenario
    NoResults --> Filtering: User types    <-- No BDD scenario
  }
```

**Action Required:** Add BDD scenario for transitioning from NoResults back to Filtering.

---

### UI Component Callback Surfaces Missing Authorization Rule

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
```

**Action Required:** Add permission and rule to authorization.yaml.

---

### Test Matrix Surfaces Missing Feature Requirement

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

**Action Required:** Update feature description with URL length limits.

---

### Authorization Rule Without Test Coverage

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
```

**Action Required:** Add owner role and ownership test cases to test matrix.

---

### Authorization Condition Surfaces Missing Data Model Field

**Gap:** Authorization condition references field not in UI data model.

```
Authorization Spec:
  rules:
    - id: owner-edit
      conditions:
        - field: owner_id

UI Spec:
  - name: DocumentCard
    data_model:
      fields:
        - name: title
        - name: content
        # No owner_id field
```

**Action Required:** Add owner_id to data model in ui.yaml.

---

## Architecture Bucket Violations

### Domain Logic Mixed with Side Effects

**Problem:**
```
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
}
```

---

### UI Component Directly Performs Side Effects

**Problem:**
```
SaveButton ->>Database: INSERT document  <-- Direct DB access from UI
```

**Resolution:** UI emits intent, orchestration handles side effects:
```
SaveButton ->> Orchestrator: on_save_requested(doc)
Orchestrator ->> DocumentRepository: save(doc)
```

---

### Orchestration Contains Domain Logic

**Problem:**
```
class CreateDocumentUseCase {
  +call(attrs)
    if attrs.title.length > 100        <-- Domain logic in orchestration
      return error
}
```

**Resolution:** Move validation to domain layer:
```
class DocumentValidator {
  +validate(attrs, existing_titles) Result  <-- Domain logic here
}

class CreateDocumentUseCase {
  +call(attrs)                              <-- Pure orchestration
}
```
