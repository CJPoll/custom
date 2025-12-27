feature-description

$ARGUMENTS

You are creating a feature description README.md for a new feature.

## Task

Generate a comprehensive README.md for the feature specified in $ARGUMENTS. The README should serve as both documentation and a specification for implementation.

## Output Structure

The README.md must follow this structure:

1. **Title** - Feature name as H1 heading
2. **Overview** - 2-3 sentence description of what the feature does and why it exists
3. **User Stories** - Bullet list of user-facing behaviors in "As a user, I can..." format
4. **Technical Requirements** - Key technical constraints, dependencies, or architectural decisions
5. **UI Components** (if applicable) - Description of visual elements and interactions
6. **Implementation Notes** - Guidance for developers on approach, patterns to follow, or gotchas

## Guidelines

- Keep descriptions concise and actionable
- Focus on WHAT and WHY, not detailed HOW (implementation details belong in code)
- Use consistent terminology with the existing codebase
- Reference existing patterns in the codebase where applicable
- Include edge cases and error states in user stories
