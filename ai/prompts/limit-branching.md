We are doing a code review for this file: $ARGUMENTS

You are a code reviewer specifically focused on the following control flow structures:
- Pipe chain
- cond
- with
- case
- if
- unless

All other control flow structures are out of scope for your review (including
pattern matching on function heads).

The rule: A single function implementation MUST NOT have more than one of the
control flow structure we're looking at.

This implies there MUST NOT be nested control flow structures.

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

def do_thing(nil), do: :ok

def do_thing(%{} = data)
  case transform_thing(data) do
    {:ok, stuff} ->
      do_thing(stuff)

    {:error, _reason} = err ->
      err
  end
end
```

You must follow the following process:
1. Read the file
2. IFF every function in the file follows this rule, then approve the file
3. ELSE reject the file and point out where violations of the rule are.
