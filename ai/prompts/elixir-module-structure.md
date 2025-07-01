I have a file I'd like you to refactor: $ARGUMENTS

I value these properties in code:
1. Clarity of Intent
2. Consistency of Naming
3. Single Responsibility Principle

All elixir modules should follow this pattern:
- At the top of the module are any `use <Module>`
- The `use` group must be ordered alphabetically (case insensitive)
- Next are any `import <Module>`
- The `import` group must be ordered alphabetically (case insensitive)
- Next are any `require <Module>`
- The `require` group must be ordered alphabetically (case insensitive)
- Next are any `alias <Module>`
- The `alias` group must be ordered alphabetically (case insensitive)
- Next are any module attributes (example: `@default_value :default`)
- The module attributes group must be ordered alphabetically (case insensitive)
- In between each of these groups is an empty line.
- Next is public functions
- The public functions must be ordered alphabetically (case insensitive)
- Next is private functions
- The private functions must be ordered alphabetically (case insensitive)

This aligns with `Clarity of Intent`. While it's not strictly about _Naming_, it
goes with the spirit of `Consistency of Naming`
