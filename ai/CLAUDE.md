= Claude

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

=== Functions named after their return value
Functions which have side effects (like CRUD functions that interact with a
database) may use imperative names like `get_*`, `list_*`, `create_*`, etc.
Other functions should not have imperative names; they should instead be named
after what they return. This aligns with the value of `Clarity of Intent`

=== Single Control-Flow Constructs
A single function should only have a single control-flow structure. Pipe chains,
cond, with, case, if, and unless are all examples of control flow structures.

While pattern matching in function heads is technically a control-flow
structure, we won't count it for the purpose of this principle.

This means a single function should not nest control flow

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

=== Never pattern match on :ok tuples or error tuples in a function head
Functions are supposed to be reusable. Pattern-matching in a function head gives
the appearance of reusability, but in reality it couples the function to
whatever returned the ok tuple | error tuple.

Instead, favor a case or with to handle them.

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

=== No single-pipe chains
Good:
```elixir
%{}
|> Map.put(:one, 1)
|> Map.put(:two, 2)
```

Good:
```elixir
Map.put(%{}, :one, 1)
```

Bad:
```elixir
%{} |> Map.put(:one, 1)
```

=== Consistent File Format
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

=== Transformation on Entity
Transformations on an entity should be defined on the entity's module.
This is "Implementation" level of abstraction.

Good:

```elixir
defmodule MyApp.Customer do
  use MyApp.Schema

  schema "customers" do
    field :name, :string
    # ... Other fields here
  end

  def new do
    %__MODULE__{}
  end

  def name(%__MODULE__{name: name}), do: name

  def name(%__MODULE__{}, name) do
    %__MODULE__{name: name}
  end
end

defmodule MyApp.Customers do
  alias MyApp.Customer

  def update_customer_name(customer_id, name) do
    Customer
    |> Repo.get(customer_id)
    |> Customer.name(name)
    |> Repo.update()
  end
end
```

Bad:

```elixir
defmodule MyApp.Customers do
  alias MyApp.Customer

  def update_customer_name(customer_id, name) do
    customer = Customers.get(Customer, customer_id)

    customer = %Customer{customer | name: name}

    Repo.update(customer)
  end
end
```

It's not 100% of the time, but you know you're hitting good abstraction levels
when the language's control flow mechanisms flow nicely. In elixir, it's often
pipe chains, clear `with` chains, etc.

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
