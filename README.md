# AshPostgresBelongsToIndex

Automatically adds AshPostgres custom indexes for `belongs_to` relationships in Ash resources.

## Installation

Add `ash_postgres_belongs_to_index` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_postgres_belongs_to_index, "~> 0.5.0"}
  ]
end
```

## Usage

```elixir
defmodule Post do
  use Ash.Resource,
    data_layer: Ash.DataLayer.Postgres,
    extensions: [AshPostgresBelongsToIndex]

  postgres do
    table "post"
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string
    attribute :content, :string
  end

  relationships do
    belongs_to :user, User
  end
end
```

For the example above, the following index will be generated. Nullable references use partial
indexes (`index_where: :not_nil`) that exclude `NULL` values:

```elixir
postgres do
  references do
    reference :user, index?: true, index_where: :not_nil
  end
end
```

Relationships configured with `allow_nil? false` use a full reference index instead. Indexes
added via `custom_indexes` (see below) get the equivalent `where: "user_id IS NOT NULL"`.

## Conflict detection

Indexes are only added when the FK is not already covered:

- A manual `reference :user, index?: true` is left alone.
- A manual `reference :user, on_delete: :delete` (no `index?`) still gets an index — added via `custom_indexes`, since a relationship can only have one `reference` entity.
- A custom index that covers the FK as its leftmost field(s) is respected, e.g. `index [:user_id, :created_at]` covers `:user_id`. Partial indexes (with a `where` clause) only count when the condition is the FK's own `IS NOT NULL`.

Only indexes declared in the resource DSL (`custom_indexes` / `references`) are considered. Indexes created by hand-written migrations are invisible to this plugin — declare them in `custom_indexes`, or exclude the relationship via `except`, to avoid duplicates.

## Multitenancy

For attribute-based multitenancy, each FK gets both a composite `[tenant_attr, fk_id]` index (for tenant-scoped queries) and a single-column `[fk_id]` index with `all_tenants?: true` (FK constraint checks are not tenant-scoped, so the composite cannot serve them).

The single-column index is named `{table}_{fk_id}_fkey_index` and is created with `include_base_filter?: false`: FK constraint checks must see all rows, so the resource's `base_filter` is deliberately not applied to it.

## License

MIT