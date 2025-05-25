# AshPostgresBelongsToIndex

Automatically adds AshPostgres custom indexes for `belongs_to` relationships in Ash resources.

## Installation

Add `ash_postgres_belongs_to_index` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_postgres_belongs_to_index, "~> 0.1.0"}
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

For the example above, the following index will be generated:

```elixir
postgres do
  custom_indexes do
    index [:user_id], name: "post_belongs_to_user_index"
  end
end
```

## License

MIT