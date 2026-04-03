# Detailed Specification Reference

This file contains the full specification templates, section schemas, and validation criteria referenced by the main [SKILL.md](./SKILL.md).

## Specification Section Templates

### Metadata Section (Required)

| Field | Description |
|-------|-------------|
| **filename** | Exact filename with extension |
| **dag-position** | Zero-indexed position in topological order |
| **dependencies** | List of files this file imports/requires |
| **dependents** | List of files that depend on this file |

### Current State Section (Required)

**existing-functions:**
- Format: Function name, arity, @spec annotation, and purpose
- Example: `defp validate_user(user_data) :: {:ok, User.t()} | {:error, atom()}`

**existing-modules:**
- Format: Module name with complete public API listing
- Validation: All public functions documented with @doc annotations

**existing-structs:**
- Format: Struct name with typed field definitions
- Example: `%User{id: integer(), email: String.t(), created_at: DateTime.t()}`

**current-dependencies:**
- Format: `alias Module.Name`, `import Module`, `use Module`, `require Module`

### Changes Section (Required)

#### Additions

**Function Specification Required Fields:**

| Field | Description |
|-------|-------------|
| **name** | Function name following snake_case convention |
| **signature** | Complete signature with @spec annotation and types |
| **purpose** | Single sentence describing function responsibility |
| **algorithm** | Step-by-step implementation using Elixir patterns |
| **parameters** | Each parameter with type and description |
| **return-value** | Type specification and semantic meaning |
| **error-handling** | All possible error tuples and their meanings |

**Module Specification Required Fields:**

| Field | Description |
|-------|-------------|
| **purpose** | Module responsibility and domain |
| **public-api** | List of exported functions with signatures |
| **private-functions** | List of internal helper functions |

#### Edits (Modifications)

| Field | Description |
|-------|-------------|
| **function-name** | Existing function being modified |
| **changes** | Specific line-by-line modifications |
| **rationale** | Requirement traceability for each change |

#### Removals

| Field | Description |
|-------|-------------|
| **type** | function, module, struct, or alias |
| **name** | Exact name of item being removed |
| **rationale** | Reason for removal with impact analysis |

### Interface Contracts Section (Required)

| Field | Description |
|-------|-------------|
| **exports** | Functions and types available to dependent files |
| **imports** | Required dependencies from other files |
| **api-guarantees** | Behavioral contracts and performance constraints |

### Test Strategy Section (Required)

**Test Case Specification Required Fields:**

| Field | Description |
|-------|-------------|
| **name** | Descriptive test case identifier |
| **purpose** | Specific behavior being validated |
| **setup** | Test environment configuration |
| **input** | Exact input parameters with types |
| **expected-output** | Precise expected results |
| **success-criteria** | Measurable pass/fail conditions |
| **requirement-mapping** | Ticket requirement ID being validated |

**Additional Fields:**
- **coverage-targets:** Percentage coverage goals for functions/lines
- **edge-cases:** Boundary conditions and error scenarios

## Validation Subagent Details

### 1. Format Validator

**Role:** Structure and Schema Compliance Specialist

**Tasks:**
- Parse specification against provided template schema
- Verify all required sections present
- Validate syntax and well-formedness
- Check nesting structure matches template exactly

**Success Criteria (threshold: 100%):**
- Specification parses without syntax errors
- All required sections present
- Section nesting matches template structure
- No extra or missing elements

**Output Fields:**
- `validation_status`: PASS or FAIL
- `syntax_errors`: List of parsing errors
- `missing_sections`: Required sections not found
- `structure_violations`: Template deviations
- `compliance_score`: 0-100% compliance rating

### 2. Content Completeness Validator

**Role:** Technical Content Completeness and Accuracy Specialist

**Tasks:**
- Verify all functions have @spec annotations with proper types
- Check algorithm descriptions use Elixir idioms and patterns
- Validate error handling follows `{:ok, result} | {:error, reason}` pattern
- Confirm parameter and return value descriptions are complete

**Success Criteria (threshold: 95%):**
- 100% of functions have complete @spec annotations
- Algorithm descriptions include step-by-step implementation
- All parameters documented with types and purposes
- Error handling patterns explicitly defined

**Output Fields:**
- `validation_status`: PASS or FAIL
- `missing_specs`: Functions without @spec annotations
- `incomplete_algorithms`: Algorithms lacking detail
- `parameter_gaps`: Undocumented parameters
- `completeness_score`: 0-100% completeness rating

### 3. Test Case Validator

**Role:** Test Case Quality and Coverage Assessment Specialist

**Tasks:**
- Verify test cases include specific inputs and expected outputs
- Check success criteria are measurable and objective
- Validate requirement mapping traces to ticket requirements
- Assess edge case coverage completeness

**Success Criteria (threshold: 90%):**
- All test cases have specific inputs and outputs
- Success criteria are objective and measurable
- Every ticket requirement mapped to at least one test
- Edge cases include boundary conditions and error scenarios

**Output Fields:**
- `validation_status`: PASS or FAIL
- `vague_test_cases`: Tests with unclear criteria
- `unmapped_requirements`: Requirements without tests
- `missing_edge_cases`: Uncovered boundary conditions
- `coverage_score`: 0-100% coverage rating

### 4. Interface Contract Validator

**Role:** Interface Contract and Dependency Accuracy Specialist

**Tasks:**
- Verify interface contracts align with DAG dependencies
- Check exports match what dependent files expect
- Validate imports correspond to actual dependencies
- Confirm API guarantees are specific and testable

**Success Criteria (threshold: 100%):**
- All exports required by dependents are specified
- All imports correspond to actual file dependencies
- Interface contracts are bidirectionally consistent
- API guarantees include performance and behavior constraints

**Output Fields:**
- `validation_status`: PASS or FAIL
- `missing_exports`: Required exports not specified
- `invalid_imports`: Imports without corresponding dependencies
- `contract_mismatches`: Inconsistent interface specifications
- `consistency_score`: 0-100% consistency rating

### 5. Elixir Convention Validator

**Role:** Elixir Language Convention and Idiom Compliance Specialist

**Tasks:**
- Check function and module names follow snake_case/PascalCase conventions
- Verify pattern matching usage in algorithm descriptions
- Validate pipe operator usage and function composition patterns
- Confirm OTP principles and GenServer patterns where applicable

**Success Criteria (threshold: 95%):**
- All naming follows Elixir conventions
- Pattern matching used appropriately in algorithms
- Functional programming idioms applied correctly
- OTP patterns used where appropriate

**Output Fields:**
- `validation_status`: PASS or FAIL
- `naming_violations`: Non-standard naming patterns
- `pattern_matching_issues`: Missed pattern matching opportunities
- `idiom_violations`: Non-idiomatic code patterns
- `convention_score`: 0-100% convention compliance

### 6. Requirement Traceability Validator

**Role:** Requirement Traceability and Coverage Verification Specialist

**Tasks:**
- Map every ticket requirement to specific file change specifications
- Verify rationale for each change traces to requirements
- Check no requirements are orphaned without specification
- Validate requirement coverage completeness across all file specs

**Success Criteria (threshold: 100%):**
- Every ticket requirement maps to at least one file specification
- All specification changes have clear rationale linking to requirements
- No requirements lack specification coverage
- Requirement coverage is complete and verifiable

**Output Fields:**
- `validation_status`: PASS or FAIL
- `orphaned_requirements`: Requirements without specification
- `unjustified_changes`: Changes without requirement rationale
- `coverage_gaps`: Areas lacking requirement coverage
- `traceability_score`: 0-100% traceability rating
