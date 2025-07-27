= Claude

== Hard Rule

- NEVER EVER UNDER ANY CIRCUMSTANCE use Process.sleep in tests

== Structure

Projects are kept at "${HOME}/dev/<project-name>".

Custom commands are saved at "${HOME}/dev/custom/ai/prompts" and symlinked into
"${HOME}/.claude/commands".

== Running things
Never use IEx. Instead, run elixir commands with `mix run -e "<elixir code here>"`

== Code Values
- Clarity of Intent
- Consistency of Naming
- Single-Responsibility Principle

== Coding Principles

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

=== Separate Composable Query Functions
Ecto queries are composable. Make use of that with query fragments to express
the intent of a query, not just the form of it.

Bad:
```elixir
defmodule MyApp.Users do
  import Ecto.Query

  def list_students_in_course(%Course{} = course) do
    query =
      from u in User,
        where: u.course_id == ^course.id,
        where: u.role == :student

    Repo.all(query)
  end
end
```

Less Bad
```elixir
defmodule MyApp.Users.UserQueries do
  def students_in_course(course_id) do
    from u in User,
      where: u.course_id == ^course.id,
      where: u.role == :student
  end
end

defmodule MyApp.Users do
  import Ecto.Query
  alias MyApp.Users.UserQueries

  def list_students_in_course(%Course{} = course) do
    course_id
    |> students_in_course()
    |> Repo.all()
  end
end
```

Good:
```elixir
defmodule MyApp.Users.UserQueries do
  def with_course_id(queryable, course_id) do
    from u in queryable, where: u.course_id == ^course_id
  end

  def with_role(queryable, role) do
    from u in queryable, where: u.role == ^role
  end
end

defmodule MyApp.Users do
  import Ecto.Query
  alias MyApp.Users.UserQueries

  def list_students_in_course(%Course{} = course) do
    User
    |> UserQueries.with_course_id(course.id)
    |> UserQueries.with_role(:student)
    |> Repo.all(query)
  end
end
```

Best:
```elixir
defmodule MyApp.Users.UserQueries do
  def with_course_id(queryable, course_id) do
    from u in queryable, where: u.course_id == ^course_id
  end

  def with_role(queryable, role) do
    from u in queryable, where: u.role == ^role
  end

  def students_in_course(queryable, course_id) do
    queryable
    |> UserQueries.with_course_id(course.id)
    |> UserQueries.with_role(:student)
  end
end

defmodule MyApp.Users do
  import Ecto.Query
  alias MyApp.Users.UserQueries

  def list_students_in_course(%Course{} = course) do
    User
    |> UserQueries.students_in_course(course.id)
    |> Repo.all(query)
  end
end
```

=== Query Functions Should Compose, Not Wrap
When using auto-generated query functions (e.g., from schemas that use macros to generate
query helpers), non-generated query functions should compose multiple operations together,
not simply wrap a single generated function.

Bad:
```elixir
defmodule MyApp.Queries do
  # This is just a wrapper - it adds no value
  def accounts_for_platform(queryable \\ AccountQueries.new(), platform_id) do
    AccountQueries.with_platform_id(queryable, platform_id)
  end
end

# Usage
Account
|> Queries.accounts_for_platform(platform_id)
|> Repo.all()
```

Good:
```elixir
defmodule MyApp.Queries do
  # This composes multiple queries together - it adds value
  def account_by_phone_numbers(queryable \\ AccountQueries.new(), account_phone, contact_phone) do
    demo_query = queryable
      |> AccountQueries.with_type(:demo)
      |> AccountQueries.with_demo_phone_number(contact_phone)
      |> select([account: a], a.id)
    
    live_query = queryable
      |> AccountQueries.with_type(:live)
      |> AccountQueries.with_phone_number(account_phone)
      |> select([account: a], a.id)

    from [account: a] in queryable,
      where: a.id in subquery(demo_query) or a.id in subquery(live_query)
  end
end

# Or just use the generated function directly
AccountQueries.new()
|> AccountQueries.with_platform_id(platform_id)
|> Repo.all()
```

=== Non-Generated Query Functions Composition

Query functions should be composable, with a clear principle of maintaining separation of concerns and avoiding over-generating functions.

Principles:
- Non-generated query functions should compose other query functions
- Each query function should do one specific thing
- Avoid generating multiple similar functions that do almost the same thing

Example of Breaking the Principle:
```elixir
defmodule UserQueries do
  def active_users do
    from u in User, where: u.status == :active
  end

  def inactive_users do
    from u in User, where: u.status == :inactive
  end

  def admin_users do
    from u in User, where: u.role == :admin
  end
```

Example Following the Principle:
```elixir
defmodule UserQueries do
  def with_status(queryable, status) do
    from u in queryable, where: u.status == ^status
  end

  def with_role(queryable, role) do
    from u in queryable, where: u.role == ^role
  end

  def active_admin_users do
    User
    |> with_status(:active)
    |> with_role(:admin)
  end
end
```
