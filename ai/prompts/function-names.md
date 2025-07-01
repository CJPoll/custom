I have a file I'd like you to refactor: $ARGUMENTS

I value these properties in code:
1. Clarity of Intent
2. Consistency of Naming
3. Single Responsibility Principle

I'd like to you look at all function and method names and ensure they follow the
following constraints:
- Functions which have side effects (like CRUD functions that interact with a
  database) may use imperative names like `get_*`, `list_*`, `create_*`, etc.
- Other functions MUST NOT have imperative names. They should instead be named
  after what they return.
- These two constraints align with the values of `Clarity of Intent` and
  `Consistency of Naming`
