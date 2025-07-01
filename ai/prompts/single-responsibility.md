I have a file I'd like you to refactor: $ARGUMENTS

I value these properties in code:
1. Clarity of Intent
2. Consistency of Naming
3. Single Responsibility Principle

I'd like you to look at all functions / methods and ensure they have only a
single control-flow structure. Pipe chains, cond, with, case, if, unless,
switch, etc. are all examples of control flow structures.

In languages that support pattern matching in function heads, that is
technically a control-flow structure, but we won't count it for the purpose of
this refactor.

This means a single function should not nest control flow.

This principle aligns with `Clarity of Intent`, `Consistency of Naming`, and
`Single Responsibility Principle`

Bad:
```elixir
def do_thing(data) do
  # Two different control flow mechanisms: Pipe chain and case
  data
  |> MyApp.transformation1()
  |> MyApp.transformation2()
  |> MyApp.transformation3()
  |> MyApp.transformation4()
  |> case do
       {:ok, stuff} ->
         do_thing(stuff)
       {:error, _reason} = err ->
         err
     end
end
```

Less bad but still bad:
```elixir
def do_thing(data) do
  # Two different control flow mechanisms: Pipe chain and case
  result =
      data
      |> MyApp.transformation1()
      |> MyApp.transformation2()
      |> MyApp.transformation3()
      |> MyApp.transformation4()

  case result do
    {:ok, stuff} ->
      do_thing(stuff)
    {:error, _reason} = err ->
      err
  end
end
```

Good:
```elixir
def transform_thing(data) do
  data
  |> MyApp.transformation1()
  |> MyApp.transformation2()
  |> MyApp.transformation3()
  |> MyApp.transformation4()
end

def do_thing(data)
  case transform_thing(data) do
    {:ok, stuff} ->
      do_thing(stuff)

    {:error, _reason} = err ->
      err
  end
end
```

