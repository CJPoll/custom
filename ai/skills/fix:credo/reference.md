# Credo Fix Reference

## Tuple Pattern Conflict Resolution

### Problem

Conflicts between `NoTupleMatchInHead` and `CaseOnBareArg` rules when handling `:ok/:error` tuple responses.

### Pattern Recognition

**Trigger**: Both violations appear for functions handling `:ok/:error` tuple responses.

**Signature**: Functions that immediately delegate to case statements on response arguments.

Common patterns that trigger this:

```elixir
# CaseOnBareArg violation — wrapper function with case-on-bare-arg
defp handle_response(response) do
  case response do
    {:ok, data} -> process_success(data)
    {:error, err} -> handle_error(err)
  end
end

# OR NoTupleMatchInHead violation — pattern matching on :ok/:error tuples
defp extract_customer_response({:ok, %{body: body}}) do
  extract_customer_id(body)
end

defp extract_customer_response({:error, err}) do
  {:error, handle_transport_error(err)}
end
```

### Resolution Strategy

**Principle**: Move case logic to the calling function and eliminate the wrapper function.

**Steps**:
1. Identify the calling function that invokes the wrapper
2. Move the case statement from wrapper to the calling function
3. Replace wrapper function call with inline case statement
4. Remove the now-unused wrapper function entirely
5. Extract any pipe chains to separate helper functions if SingleControlFlow violations result

### Example Transformation

**Before**:
```elixir
defp do_api_call(params, opts) do
  response = make_request(params, opts)
  handle_response(response)  # Wrapper function call
end

# CaseOnBareArg violation
defp handle_response(response) do
  case response do
    {:ok, data} -> process_success(data)
    {:error, err} -> handle_error(err)
  end
end
```

**After**:
```elixir
defp do_api_call(params, opts) do
  response = make_request(params, opts)

  case response do  # Case moved to caller
    {:ok, data} -> process_success(data)
    {:error, err} -> handle_error(err)
  end
end

# Wrapper function removed entirely
```

### Follow-up Fixes

If SingleControlFlow violations result from pipe + case combination:

```elixir
# Extract the pipe chain to a dedicated helper
defp do_api_call(params, opts) do
  response = make_api_request(params, opts)  # Extracted pipe chain

  case response do
    {:ok, data} -> process_success(data)
    {:error, err} -> handle_error(err)
  end
end

defp make_api_request(params, opts) do
  opts
  |> Keyword.get(:options, [])
  |> base_request()
  |> Req.post(url: "/endpoint", form: params)
end
```

### Validation

- Calling function contains the case statement logic
- Wrapper function is completely removed
- No new SingleControlFlow violations introduced
- Semantic behavior preserved exactly

## Prioritization Algorithm

### Scoring Factors

| Factor | Weight | Description |
|--------|--------|-------------|
| Severity impact | 50% | Critical=20, High=15, Normal=8, Low=3 |
| Fix complexity | 25% | Auto-fixable=10, Config-dependent=6, Manual=3 |
| File importance | 15% | Core business logic=10, App support=7, Config=5, Test=3 |
| Violation density | 10% | violation_count / file_line_count * 100 |

### Dependency Conflict Rules

- If files share `use` or `import` relationships, select only one per dependency group
- Prefer files with Critical/High violations over lower severity
- Ensure selected files have non-overlapping modification scope
- Avoid simultaneous modification of macro-defining and macro-using files
