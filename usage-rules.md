# Rules for working with AshPostgresBelongsToIndex

AshPostgresBelongsToIndex automatically adds PostgreSQL indexes for all `belongs_to` relationships in Ash resources.

## Usage

Add the extension to your resource and indexes will be automatically created for all `belongs_to` relationships:

```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPostgresBelongsToIndex]

  relationships do
    belongs_to :user, MyApp.User
    belongs_to :category, MyApp.Category
  end
end
```

This automatically generates:

```elixir
postgres do
  references do
    reference :user, index?: true
    reference :category, index?: true
  end
end
```

## Excluding Relationships

Use the `except` option to exclude specific relationships:

```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPostgresBelongsToIndex]

  postgres_belongs_to_index do
    except [:optional_reference]
  end

  relationships do
    belongs_to :user, MyApp.User  # indexed
    belongs_to :optional_reference, MyApp.Other  # not indexed
  end
end
```

## Automatic Exclusions

The following are automatically excluded:
- Multitenant attributes (e.g., `:tenant_id`)
- Relationships already manually defined in the `references` block

## When to use

- Recommended for all resources using AshPostgres
- Most `belongs_to` relationships are joined in queries, so indexes improve performance
- Use `except` only for special cases where indexing is not needed

## Migration

Generate migrations after adding the extension:

```bash
mix ash.codegen add_belongs_to_indexes
```

