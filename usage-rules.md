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
    reference :user, index?: true, index_where: :not_nil
    reference :category, index?: true, index_where: :not_nil
  end
end
```

Nullable relationships use partial indexes that exclude `NULL` values. Relationships configured
with `allow_nil? false` use full indexes.

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

## Conflict Detection

Indexes are only added when not already covered:
- A manual `reference` with `index?: true` counts as covered
- A manual `reference` without `index?` is NOT skipped — the index is added via `custom_indexes` instead (since a second `reference` entity is not allowed)
- A custom index whose leftmost fields cover the FK column counts as covered (e.g., `index [:fk_id, :created_at]` covers `:fk_id`)

## Multitenancy

For resources with attribute-based multitenancy, two indexes are created per FK:
- A composite `[tenant_attr, fk_id]` index (via tenant prefixing) for tenant-scoped queries
- A single-column `[fk_id]` index with `all_tenants?: true`, needed because FK constraint checks (e.g., deletes on the referenced table) are not tenant-scoped

The tenant attribute's own `belongs_to` gets a single `[tenant_attr]` index only when no other index already starts with it.

## When to use

- Recommended for all resources using AshPostgres
- Most `belongs_to` relationships are joined in queries, so indexes improve performance
- Use `except` only for special cases where indexing is not needed

## Migration

Generate migrations after adding the extension:

```bash
mix ash.codegen add_belongs_to_indexes
```
