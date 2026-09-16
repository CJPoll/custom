---
name: beryl:ruby-testing-pyramid
description: Write Ruby tests following the testing pyramid pattern with exhaustive domain tests, mocked manager tests, and minimal integration tests. Use when writing tests for Ruby projects with hexagonal architecture, implementing test-driven development, or creating test matrices.
user-invocable: true
---

# Ruby Testing Pyramid

This skill provides guidance for writing Ruby tests following the testing pyramid approach, optimized for hexagonal architecture with domain/adapter/manager layers.

## IMPORTANT: Check for Project-Specific Architecture

**Before writing tests, ALWAYS check for a project-specific feature architecture skill** (e.g., `grimoire-feature-architecture`, `myproject-feature-architecture`).

Use the Skill tool to invoke it if it exists:
```ruby
Skill(skill: "grimoire-feature-architecture")
```

The architecture skill will define:
- Layer structure (domain/adapters/managers/ui)
- Dependency injection patterns
- Testing requirements per layer

## Testing Pyramid Overview

```
        /\
       /  \      Small number of integration tests
      /____\     (slow, expensive, non-exhaustive)
     /      \
    /        \   Exhaustive manager tests with mocks
   /__________\  (moderate speed, mocked adapters)
  /            \
 /              \ Exhaustive domain tests
/________________\ (fast, pure functions, no mocks)
```

### Layer Testing Strategy

| Layer | Test Coverage | Speed | Mocking | Purpose |
|-------|--------------|-------|---------|---------|
| **Domain** | Exhaustive | Very Fast | None | Pure logic, all edge cases |
| **Adapters** | Moderate | Slow | Real DB (in-memory) | Repository contract verification |
| **Managers** | Exhaustive | Fast | Mock adapters | Orchestration logic |
| **Integration** | Minimal | Very Slow | Real adapters | Happy path only |
| **UI** | Manual | N/A | N/A | GTK is hard to test |

## Implementation Order

When implementing a feature, follow this sequence:

1. **Domain Layer Tests** → Domain Layer Implementation
2. **Adapter Layer Tests** → Adapter Layer Implementation
3. **Manager Layer Tests** → Manager Layer Implementation
4. **UI Layer** (minimal or no automated tests)
5. **Integration Tests** (happy path only)

**Skip any layers not required by the feature specification.**

## Domain Layer Testing

### Characteristics
- **Exhaustive**: Test every edge case, boundary condition, validation
- **Fast**: Pure functions, no I/O, no setup/teardown
- **No Mocking**: Domain has no dependencies
- **Coverage Goal**: 100% of domain logic

### Example: Pure Function Domain Logic

```ruby
# test/review/domain/calibration_calculator_test.rb
require 'test_helper'

class CalibrationCalculatorTest < Minitest::Test
  # Test all combinations exhaustively

  def test_correct_grade_maps_to_3
    assert_equal 0, Review::Domain::CalibrationCalculator.calculate_error(3, :correct)
    assert_equal 1, Review::Domain::CalibrationCalculator.calculate_error(2, :correct)
    assert_equal 2, Review::Domain::CalibrationCalculator.calculate_error(1, :correct)
    assert_equal 3, Review::Domain::CalibrationCalculator.calculate_error(0, :correct)
  end

  def test_partial_grade_maps_to_1
    assert_equal 2, Review::Domain::CalibrationCalculator.calculate_error(3, :partial)
    assert_equal 1, Review::Domain::CalibrationCalculator.calculate_error(2, :partial)
    assert_equal 0, Review::Domain::CalibrationCalculator.calculate_error(1, :partial)
    assert_equal 1, Review::Domain::CalibrationCalculator.calculate_error(0, :partial)
  end

  def test_incorrect_grade_maps_to_0
    assert_equal 3, Review::Domain::CalibrationCalculator.calculate_error(3, :incorrect)
    assert_equal 2, Review::Domain::CalibrationCalculator.calculate_error(2, :incorrect)
    assert_equal 1, Review::Domain::CalibrationCalculator.calculate_error(1, :incorrect)
    assert_equal 0, Review::Domain::CalibrationCalculator.calculate_error(0, :incorrect)
  end

  def test_invalid_confidence_raises_error
    assert_raises(ArgumentError) do
      Review::Domain::CalibrationCalculator.calculate_error(4, :correct)
    end
  end

  def test_invalid_grade_raises_error
    assert_raises(ArgumentError) do
      Review::Domain::CalibrationCalculator.calculate_error(2, :unknown)
    end
  end
end
```

### Example: Struct Domain Logic

```ruby
# test/review/domain/prompt_renderer_test.rb
require 'test_helper'

class PromptRendererTest < Minitest::Test
  def setup
    @concept = Concepts::Domain::Concept.new(
      id: 'test-id',
      name: 'Hindley-Milner',
      parts: 'constraints, unification, types',
      dynamics: 'generate → unify → substitute',
      feedback_loop: 'type errors refine constraints'
    )

    @template = Review::Domain::PromptTemplate.new(
      id: 'tmpl-1',
      channel: :verbal,
      prompt_type: :explain,
      template: 'Explain {concept.name} system: {concept.dynamics}',
      answer_type: :text
    )
  end

  def test_renders_simple_placeholders
    result = Review::Domain::PromptRenderer.render(@template, @concept)

    assert_equal 'Explain Hindley-Milner system: generate → unify → substitute',
                 result[:text]
  end

  def test_extracts_expected_elements
    result = Review::Domain::PromptRenderer.render(@template, @concept)

    assert_includes result[:expected_elements], 'generate → unify → substitute'
  end

  def test_missing_placeholder_returns_error
    bad_template = @template.dup
    bad_template.template = 'Explain {concept.nonexistent}'

    result = Review::Domain::PromptRenderer.render(bad_template, @concept)

    assert result[:error]
    assert_match /nonexistent/, result[:error]
  end

  def test_handles_multiline_templates
    multiline_template = @template.dup
    multiline_template.template = <<~PROMPT
      Draw the {concept.name} system showing:
      - {concept.parts}
      - The feedback loop: {concept.feedback_loop}
    PROMPT

    result = Review::Domain::PromptRenderer.render(multiline_template, @concept)

    assert_includes result[:text], 'constraints, unification, types'
    assert_includes result[:text], 'type errors refine constraints'
  end
end
```

## Adapter Layer Testing

### Characteristics
- **Moderate Coverage**: Test repository contract, not SQL syntax
- **In-Memory Database**: Use SQLite `:memory:` for speed
- **Real Database Schema**: Run migrations for realistic tests
- **Coverage Goal**: Core CRUD operations + constraints

### Example: Repository Testing

```ruby
# test/review/adapters/review_session_repository_test.rb
require 'test_helper'
require 'sqlite3'

class ReviewSessionRepositoryTest < Minitest::Test
  def setup
    @db = SQLite3::Database.new(':memory:')
    @db.results_as_hash = true

    # Run schema migrations
    Review::Adapters::Schema.create_tables(@db)

    @repo = Review::Adapters::ReviewSessionRepository.new(@db)
  end

  def teardown
    @db.close
  end

  def test_save_returns_persisted_session
    session = create_session(
      id: 'session-1',
      concept_id: 'concept-1',
      grade: :correct
    )

    result = @repo.save(session)

    assert_equal session.id, result.id
    assert_equal :correct, result.grade
  end

  def test_find_returns_session_by_id
    session = create_session(id: 'session-1')
    @repo.save(session)

    found = @repo.find('session-1')

    assert_equal 'session-1', found.id
  end

  def test_find_returns_nil_for_nonexistent_id
    assert_nil @repo.find('nonexistent')
  end

  def test_repository_is_append_only_no_updates
    session = create_session(id: 'session-1', grade: :correct)
    @repo.save(session)

    # Attempt to update should raise error
    assert_raises(Review::Adapters::ImmutableRepositoryError) do
      @repo.update(session)
    end
  end

  def test_repository_is_append_only_no_deletes
    session = create_session(id: 'session-1')
    @repo.save(session)

    assert_raises(Review::Adapters::ImmutableRepositoryError) do
      @repo.delete('session-1')
    end
  end

  def test_find_by_concept_returns_sessions_ordered_by_recency
    @repo.save(create_session(id: '1', concept_id: 'c1', reviewed_at: '2024-01-01'))
    @repo.save(create_session(id: '2', concept_id: 'c1', reviewed_at: '2024-01-03'))
    @repo.save(create_session(id: '3', concept_id: 'c1', reviewed_at: '2024-01-02'))

    sessions = @repo.find_by_concept('c1')

    assert_equal ['2', '3', '1'], sessions.map(&:id)
  end

  private

  def create_session(**attrs)
    defaults = {
      id: SecureRandom.uuid,
      concept_id: 'test-concept',
      template_id: 'test-template',
      channel: :verbal,
      prompt_text: 'Test prompt',
      confidence_before: 2,
      response: 'Test response',
      grade: :correct,
      confidence_error: 1,
      reviewed_at: Time.now.iso8601
    }

    Review::Domain::ReviewSession.new(**defaults.merge(attrs))
  end
end
```

## Manager Layer Testing

### Characteristics
- **Exhaustive**: Test all orchestration paths
- **Fast**: Mock all adapters and cross-domain dependencies
- **Focus on Logic**: Test manager decisions, not repository behavior
- **Coverage Goal**: All code paths, error handling, edge cases

### Example: Manager Testing with Mocks

```ruby
# test/review/managers/review_session_manager_test.rb
require 'test_helper'
require 'minitest/mock'

class ReviewSessionManagerTest < Minitest::Test
  def setup
    @prompt_repo = Minitest::Mock.new
    @session_repo = Minitest::Mock.new
    @mastery_manager = Minitest::Mock.new
    @concept_repo = Minitest::Mock.new
    @scheduler_manager = Minitest::Mock.new

    @manager = Review::Managers::ReviewSessionManager.new(
      prompt_template_repo: @prompt_repo,
      review_session_repo: @session_repo,
      mastery_manager: @mastery_manager,
      concept_repo: @concept_repo,
      scheduler_manager: @scheduler_manager
    )
  end

  def test_start_review_returns_rendered_prompt
    concept = mock_concept
    template = mock_template

    @concept_repo.expect(:find, concept, ['concept-1'])
    @prompt_repo.expect(:find_by_channel, template, [:verbal])

    result = @manager.start_review('concept-1', :verbal)

    assert result[:ok]
    assert_equal 'Hindley-Milner', result[:ok][:concept].name
    assert_includes result[:ok][:prompt_text], 'Explain'

    @concept_repo.verify
    @prompt_repo.verify
  end

  def test_start_review_returns_error_for_missing_concept
    @concept_repo.expect(:find, nil, ['nonexistent'])

    result = @manager.start_review('nonexistent', :verbal)

    assert result[:error]
    assert_equal 'Concept not found', result[:error]

    @concept_repo.verify
  end

  def test_start_review_returns_error_for_missing_template
    concept = mock_concept

    @concept_repo.expect(:find, concept, ['concept-1'])
    @prompt_repo.expect(:find_by_channel, nil, [:diagram])

    result = @manager.start_review('concept-1', :diagram)

    assert result[:error]
    assert_equal 'No template available', result[:error]

    @concept_repo.verify
    @prompt_repo.verify
  end

  def test_complete_review_saves_session_and_updates_mastery
    session_data = {
      concept_id: 'concept-1',
      channel: :verbal,
      template_id: 'tmpl-1',
      prompt_text: 'Test prompt',
      confidence_before: 2,
      response: 'My response',
      grade: :correct
    }

    saved_session = Review::Domain::ReviewSession.new(
      id: 'session-1',
      **session_data,
      confidence_error: 1,
      reviewed_at: Time.now.iso8601
    )

    @session_repo.expect(:save, saved_session, [Review::Domain::ReviewSession])
    @mastery_manager.expect(
      :update_channel_mastery,
      { ok: true },
      ['concept-1', :verbal, :correct]
    )

    result = @manager.complete_review(**session_data)

    assert result[:ok]
    assert_equal 'session-1', result[:ok].id

    @session_repo.verify
    @mastery_manager.verify
  end

  def test_next_review_delegates_to_scheduler
    next_review_data = { concept_id: 'concept-1', channel: :verbal }

    @scheduler_manager.expect(:next_review, { ok: next_review_data }, [])

    # After getting next review, it calls start_review
    concept = mock_concept
    template = mock_template
    @concept_repo.expect(:find, concept, ['concept-1'])
    @prompt_repo.expect(:find_by_channel, template, [:verbal])

    result = @manager.next_review

    assert result[:ok]

    @scheduler_manager.verify
    @concept_repo.verify
    @prompt_repo.verify
  end

  private

  def mock_concept
    Concepts::Domain::Concept.new(
      id: 'concept-1',
      name: 'Hindley-Milner',
      parts: 'constraints',
      dynamics: 'unify',
      feedback_loop: 'refine'
    )
  end

  def mock_template
    Review::Domain::PromptTemplate.new(
      id: 'tmpl-1',
      channel: :verbal,
      prompt_type: :explain,
      template: 'Explain {concept.name}',
      answer_type: :text
    )
  end
end
```

## Integration Testing

### Characteristics
- **Minimal**: Only test critical happy paths
- **Slow**: Use real database, real adapters
- **Non-Exhaustive**: Edge cases covered by unit tests
- **Coverage Goal**: Core user workflows work end-to-end

### Example: Integration Test

```ruby
# test/integration/review_session_integration_test.rb
require 'test_helper'

class ReviewSessionIntegrationTest < Minitest::Test
  def setup
    # Use real database (in-memory for speed)
    @db = SQLite3::Database.new(':memory:')
    @db.results_as_hash = true

    # Create all schemas
    Review::Adapters::Schema.create_tables(@db)
    Concepts::Adapters::Schema.create_tables(@db)
    Mastery::Adapters::Schema.create_tables(@db)

    # Create real repositories
    @concept_repo = Concepts::Adapters::ConceptRepository.new(@db)
    @prompt_repo = Review::Adapters::PromptTemplateRepository.new(@db)
    @session_repo = Review::Adapters::ReviewSessionRepository.new(@db)
    @mastery_repo = Mastery::Adapters::MasteryRepository.new(@db)

    # Create real managers
    @mastery_manager = Mastery::Managers::MasteryManager.new(
      mastery_repo: @mastery_repo
    )

    @review_manager = Review::Managers::ReviewSessionManager.new(
      prompt_template_repo: @prompt_repo,
      review_session_repo: @session_repo,
      mastery_manager: @mastery_manager,
      concept_repo: @concept_repo,
      scheduler_manager: nil  # Not needed for this test
    )

    # Seed test data
    seed_test_data
  end

  def teardown
    @db.close
  end

  def test_complete_review_workflow_happy_path
    # 1. Start a review
    result = @review_manager.start_review('hindley-milner', :verbal)
    assert result[:ok]

    prompt_data = result[:ok]
    assert_equal 'Hindley-Milner', prompt_data[:concept].name
    assert_includes prompt_data[:prompt_text], 'Explain'

    # 2. Complete the review
    completion_result = @review_manager.complete_review(
      concept_id: 'hindley-milner',
      channel: :verbal,
      template_id: prompt_data[:template].id,
      prompt_text: prompt_data[:prompt_text],
      confidence_before: 2,
      response: 'HM is a type inference algorithm',
      grade: :correct
    )

    assert completion_result[:ok]
    session = completion_result[:ok]

    # 3. Verify session was saved
    saved_session = @session_repo.find(session.id)
    assert_equal :correct, saved_session.grade
    assert_equal 2, saved_session.confidence_before

    # 4. Verify mastery was updated
    mastery = @mastery_repo.find_by_concept_and_channel(
      'hindley-milner',
      :verbal
    )
    assert mastery
    # Mastery should have increased after correct answer
  end

  private

  def seed_test_data
    # Create a concept
    concept = Concepts::Domain::Concept.new(
      id: 'hindley-milner',
      name: 'Hindley-Milner',
      core_claim: 'Type inference algorithm',
      parts: 'constraints, unification',
      dynamics: 'generate → unify → substitute'
    )
    @concept_repo.save(concept)

    # Create a prompt template
    template = Review::Domain::PromptTemplate.new(
      id: 'verbal-explain-1',
      channel: :verbal,
      prompt_type: :explain,
      template: 'Explain {concept.name} in your own words',
      answer_type: :text
    )
    @prompt_repo.save(template)

    # Initialize mastery
    mastery = Mastery::Domain::ChannelMastery.new(
      concept_id: 'hindley-milner',
      channel: :verbal,
      strength: 0.0,
      next_review_at: Time.now.iso8601
    )
    @mastery_repo.save(mastery)
  end
end
```

## UI Testing

**General Approach**: Manual testing is preferred for GTK applications.

### Why Manual Testing for UI?

1. **GTK is hard to unit test** - Requires X server or headless environment
2. **Signal testing is brittle** - GTK signal chains are complex
3. **Visual bugs require visual verification** - Alignment, colors, spacing
4. **Fast feedback from manual testing** - Run app, click button, verify

### Minimal UI Testing (If Required)

```ruby
# test/review/ui/confidence_selector_test.rb
require 'test_helper'

class ConfidenceSelectorTest < Minitest::Test
  # Only test critical interaction contracts

  def test_on_select_callback_invoked_with_confidence_level
    selected_confidence = nil

    selector = Review::UI::ConfidenceSelector.new(
      on_select: ->(confidence) { selected_confidence = confidence }
    )

    # Simulate button click (if GTK environment available)
    selector.select_confidence(2)

    assert_equal 2, selected_confidence
  end

  def test_selector_locks_after_selection
    selector = Review::UI::ConfidenceSelector.new(
      on_select: ->(_) {}
    )

    refute selector.locked?

    selector.select_confidence(2)

    assert selector.locked?
  end
end
```

## Test File Organization

```
test/
├── test_helper.rb              # Minitest setup, shared fixtures
├── review/
│   ├── domain/
│   │   ├── calibration_calculator_test.rb  # Pure logic tests
│   │   ├── prompt_renderer_test.rb
│   │   └── review_session_test.rb          # Struct behavior
│   ├── adapters/
│   │   ├── review_session_repository_test.rb  # Repository tests
│   │   └── prompt_template_repository_test.rb
│   ├── managers/
│   │   ├── review_session_manager_test.rb     # Mocked tests
│   │   └── calibration_manager_test.rb
│   └── ui/
│       └── confidence_selector_test.rb        # Minimal/optional
└── integration/
    └── review_session_integration_test.rb     # Happy path only
```

## Running Tests

```bash
# Run all tests
bundle exec rake test

# Run specific layer
ruby -Itest test/review/domain/*_test.rb

# Run single test file
ruby -Itest test/review/domain/calibration_calculator_test.rb

# Run single test method
ruby -Itest test/review/domain/calibration_calculator_test.rb \
  -n test_correct_grade_maps_to_3
```

## Test Helper Setup

```ruby
# test/test_helper.rb
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'minitest/autorun'
require 'minitest/pride'  # Colorful output

# Load all lib files
Dir[File.expand_path('../lib/**/*.rb', __dir__)].each { |f| require f }

# Shared fixtures and helpers
module TestHelpers
  def create_concept(**attrs)
    defaults = {
      id: SecureRandom.uuid,
      name: 'Test Concept',
      parts: 'test parts'
    }
    Concepts::Domain::Concept.new(**defaults.merge(attrs))
  end
end

class Minitest::Test
  include TestHelpers
end
```

## Best Practices

### 1. Test Naming Conventions

```ruby
# ✅ Good - describes behavior
def test_calculates_error_for_overconfident_user
def test_returns_error_when_concept_not_found
def test_saves_session_and_updates_mastery

# ❌ Bad - vague or implementation-focused
def test_method1
def test_calculation
def test_repo
```

### 2. Arrange-Act-Assert Pattern

```ruby
def test_complete_review_updates_mastery
  # Arrange - set up test data
  session_data = { concept_id: 'c1', grade: :correct }
  @mastery_manager.expect(:update_channel_mastery, { ok: true }, ['c1', :verbal, :correct])

  # Act - perform the operation
  result = @manager.complete_review(**session_data)

  # Assert - verify expectations
  assert result[:ok]
  @mastery_manager.verify
end
```

### 3. One Logical Assertion Per Test

```ruby
# ✅ Good - focused test
def test_correct_grade_maps_to_value_3
  assert_equal 3, grade_to_value(:correct)
end

def test_partial_grade_maps_to_value_1
  assert_equal 1, grade_to_value(:partial)
end

# ❌ Bad - testing multiple things
def test_grade_mapping
  assert_equal 3, grade_to_value(:correct)
  assert_equal 1, grade_to_value(:partial)
  assert_equal 0, grade_to_value(:incorrect)
end
```

### 4. Mock Verification

Always verify mocks were called:

```ruby
def test_delegates_to_repository
  @repo.expect(:find, concept, ['id-1'])

  @manager.get_concept('id-1')

  @repo.verify  # ✅ Essential - verifies :find was called
end
```

### 5. Test Independence

```ruby
# ✅ Good - each test is independent
def setup
  @db = SQLite3::Database.new(':memory:')
  # Fresh database per test
end

def teardown
  @db.close
end

# ❌ Bad - tests share state
def setup
  @db = SQLite3::Database.new('test.db')  # Shared file
end
```

## Quick Reference

| Layer | Coverage | Speed | Mocking | Run Frequency |
|-------|----------|-------|---------|---------------|
| Domain | 100% | <1s | None | Every save |
| Adapters | 80% | ~1s | None (in-memory DB) | Every save |
| Managers | 100% | <1s | All dependencies | Every save |
| Integration | 20% | ~5s | None | Before commit |
| UI | 0-10% | N/A | N/A | Manual |

## TDD Workflow

1. Write **domain test** (red)
2. Implement **domain logic** (green)
3. Refactor domain
4. Write **manager test** with mocked adapters (red)
5. Implement **manager** (green)
6. Refactor manager
7. Write **adapter test** (red)
8. Implement **adapter** (green)
9. Write **integration test** for happy path
10. Implement **UI** (manual testing)

## Common Pitfalls

### ❌ Over-Mocking

```ruby
# Bad - mocking domain objects
concept_mock = Minitest::Mock.new
concept_mock.expect(:name, 'Test')
```

Domain objects are cheap - use real ones:

```ruby
# Good - use real domain object
concept = Concepts::Domain::Concept.new(name: 'Test')
```

### ❌ Testing Implementation Details

```ruby
# Bad - testing private method
def test_private_helper_method
  assert @manager.send(:private_method, arg)
end
```

Test public interface only:

```ruby
# Good - test public behavior
def test_completes_review_successfully
  result = @manager.complete_review(data)
  assert result[:ok]
end
```

### ❌ Brittle Integration Tests

```ruby
# Bad - testing every edge case in integration
def test_integration_with_invalid_concept
def test_integration_with_missing_template
def test_integration_with_invalid_confidence
```

Leave edge cases to unit tests:

```ruby
# Good - integration tests happy path only
def test_complete_review_workflow_happy_path
  # Just verify the pieces work together
end
```

## Additional Resources

- Minitest Documentation: https://docs.seattlerb.org/minitest/
- Testing Pyramid: https://martinfowler.com/bliki/TestPyramid.html
- Mocks vs Stubs: https://martinfowler.com/articles/mocksArentStubs.html
