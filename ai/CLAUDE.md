= Claude

== Hard Rule

- NEVER EVER UNDER ANY CIRCUMSTANCE use Process.sleep in tests for arbitrary timing delays
  - ❌ BAD: `Process.sleep(2000); assert something` (hoping 2s is enough)
  - ✅ OK: Polling loops with condition checking and timeout (e.g., `for i in 1..100; do if [condition]; then break; fi; sleep 0.1; done`)
- NEVER EVER UNDER ANY CIRCUMSTANCE use `Application.put_env`
- NEVER make system-level changes (especially daemons, system services, /etc files, sudo commands) without the user's express direction
- It's OK to make changes to files under ~/dev or ~/.local/worktrees without asking
- For system changes: provide instructions for the user to execute, do NOT execute them yourself

== Structure

Projects are kept at "${HOME}/dev/<project-name>".

Worktrees for those projects are kept at
"${HOME}/.local/worktrees/<project-name>/<git-branch-name>"

Custom commands are saved at "${HOME}/dev/custom/ai/prompts" and symlinked into
"${HOME}/.claude/commands".

== Running things
Never use IEx. Instead, run elixir commands with `mix run -e "<elixir code here>"`

== Code Values
- Clarity of Intent
- Consistency of Naming
- Single-Responsibility Principle

== Coding Principles

=== Single-Responsibility

Sometimes a linter will tell you a function has too many control-flow
structures. When this happens, favor extracting pipe chains to other functions
before extracting other control-flow structures like case, with, etc.

=== Never pattern match on :ok tuples or error tuples in a function head
Functions are supposed to be reusable. Pattern-matching in a function head gives
the appearance of reusability, but in reality it couples the function to
whatever returned the ok tuple | error tuple.

Instead, refactor the _calling function_ to use a case statement

Bad:
```elixir
  def create_platform(attrs, owner) do
    Multi.new()
    |> Multi.insert(:platform, Platform.insert_changeset(attrs, owner))
    |> Multi.insert(:geo_settings, &create_geo_settings/1)
    |> Multi.insert(:custom_styles, &create_custom_styles/1)
    |> Oban.insert(:billing, &schedule_platform_initialization/1)
    |> Repo.transaction()
    |> handle_platform_creation_result()
  end

  defp handle_platform_creation_result({:ok, %{geo_settings: geo_settings, platform: platform}}) do
    {:ok, %{platform | geo_settings: geo_settings}}
  end

  defp handle_platform_creation_result({:error, :platform, changeset, _changes}) do
    {:error, changeset}
  end

  defp handle_platform_creation_result({:error, :billing, reason, _changes}) do
    {:error, reason}
  end
```

Good:
```elixir
  def create_platform(attrs, owner) do
    case do_create_platform(attrs, owner) do
      {:ok, %{geo_settings: geo_settings, platform: platform}} ->
        {:ok, %{platform | geo_settings: geo_settings}}

      {:error, :platform, changeset, _changes} ->
        {:error, changeset}

      {:error, :billing, reason, _changes} ->
        {:error, reason}
    end
  end

  defp do_create_platform(attrs, owner) do
    attrs
    |> insert_platform_multi(owner)
    |> Oban.insert(:billing, &schedule_platform_initialization/1)
    |> Repo.transaction()
  end

  # Could be made public for testing multi composition, or extracted to another
  # module.
  defp insert_platform_multi(attrs, owner) do
    Multi.new()
    |> Multi.insert(:platform, Platform.insert_changeset(attrs, owner))
    |> Multi.insert(:geo_settings, &create_geo_settings/1)
    |> Multi.insert(:custom_styles, &create_custom_styles/1)
  end
```
