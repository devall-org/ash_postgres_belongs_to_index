defmodule AshPostgresBelongsToIndex.PartialIndexTest do
  use ExUnit.Case, async: true

  defmodule Repo do
    use AshPostgres.Repo,
      otp_app: :ash_postgres_belongs_to_index,
      warn_on_missing_ash_functions?: false

    def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
  end

  defmodule Author do
    use Ash.Resource, domain: nil, data_layer: AshPostgres.DataLayer

    attributes do
      integer_primary_key :id
    end

    postgres do
      table "authors"
      repo Repo
    end
  end

  defmodule Post do
    use Ash.Resource,
      domain: nil,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshPostgresBelongsToIndex]

    attributes do
      uuid_primary_key :id
    end

    relationships do
      belongs_to :optional_author, Author
      belongs_to :required_author, Author, allow_nil?: false
    end

    postgres do
      table "posts"
      repo Repo
    end
  end

  defmodule Domain do
    use Ash.Domain

    resources do
      resource Author
      resource Post
    end
  end

  defmodule IndexTarget do
    use Ash.Resource, domain: nil, data_layer: AshPostgres.DataLayer

    attributes do
      integer_primary_key :id
    end

    postgres do
      table "index_targets"
      repo Repo
    end
  end

  defmodule FullIndexSource do
    use Ash.Resource, domain: nil, data_layer: AshPostgres.DataLayer

    attributes do
      integer_primary_key :id
    end

    relationships do
      belongs_to :target, IndexTarget
    end

    postgres do
      table "index_sources"
      repo Repo

      references do
        reference :target, index?: true
      end
    end
  end

  defmodule PartialIndexSource do
    use Ash.Resource, domain: nil, data_layer: AshPostgres.DataLayer

    attributes do
      integer_primary_key :id
    end

    relationships do
      belongs_to :target, IndexTarget
    end

    postgres do
      table "index_sources"
      repo Repo

      references do
        reference :target, index?: true, index_where: "target_id IS NOT NULL"
      end
    end
  end

  defmodule FullIndexDomain do
    use Ash.Domain

    resources do
      resource IndexTarget
      resource FullIndexSource
    end
  end

  defmodule PartialIndexDomain do
    use Ash.Domain

    resources do
      resource IndexTarget
      resource PartialIndexSource
    end
  end

  test "nullable relationships use partial indexes and required relationships use full indexes" do
    references = AshPostgres.DataLayer.Info.references(Post)

    optional_author = Enum.find(references, &(&1.relationship == :optional_author))
    required_author = Enum.find(references, &(&1.relationship == :required_author))

    assert optional_author.index?
    assert optional_author.index_where == :not_nil
    assert required_author.index?
    assert is_nil(required_author.index_where)
  end

  @tag :tmp_dir
  test "generated migrations use a partial index only for nullable relationships", %{
    tmp_dir: tmp_dir
  } do
    migration_path = Path.join(tmp_dir, "migrations")

    AshPostgres.MigrationGenerator.generate(Domain,
      snapshot_path: Path.join(tmp_dir, "snapshots"),
      migration_path: migration_path,
      quiet: true,
      format: false,
      auto_name: true
    )

    migration =
      migration_path
      |> Path.join("**/*_migrate_resources*.exs")
      |> Path.wildcard()
      |> Enum.map_join(&File.read!/1)

    assert migration =~
             ~S{create index(:posts, [:optional_author_id], where: "optional_author_id IS NOT NULL")}

    assert migration =~ ~S{create index(:posts, [:required_author_id])}
  end

  @tag :tmp_dir
  test "changing index_where replaces only the reference index", %{tmp_dir: tmp_dir} do
    migration_path = Path.join(tmp_dir, "migrations")
    snapshot_path = Path.join(tmp_dir, "snapshots")

    AshPostgres.MigrationGenerator.generate(FullIndexDomain,
      snapshot_path: snapshot_path,
      migration_path: migration_path,
      quiet: true,
      format: false,
      auto_name: true
    )

    AshPostgres.MigrationGenerator.generate(PartialIndexDomain,
      snapshot_path: snapshot_path,
      migration_path: migration_path,
      quiet: true,
      format: false,
      auto_name: true
    )

    migration =
      migration_path
      |> Path.join("**/*_migrate_resources*.exs")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "extensions"))
      |> Enum.sort()
      |> List.last()
      |> File.read!()

    assert migration =~ ~S{drop_if_exists index(:index_sources, [:target_id])}

    assert migration =~
             ~S{create index(:index_sources, [:target_id], where: "target_id IS NOT NULL")}

    refute migration =~ ~S{drop constraint(:index_sources, "index_sources_target_id_fkey")}
    refute migration =~ ~S{modify :target_id, references(}
    refute migration =~ ~S{modify :target_id,}
  end

  test "manual references without index? get partial custom indexes only for nullable FKs" do
    defmodule ManualRefPost do
      use Ash.Resource,
        domain: nil,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshPostgresBelongsToIndex]

      attributes do
        uuid_primary_key :id
      end

      relationships do
        belongs_to :optional_author, Author
        belongs_to :required_author, Author, allow_nil?: false
      end

      postgres do
        table "manual_ref_posts"
        repo Repo

        references do
          reference :optional_author, on_delete: :delete
          reference :required_author, on_delete: :delete
        end
      end
    end

    custom_indexes = AshPostgres.DataLayer.Info.custom_indexes(ManualRefPost)

    optional_index = Enum.find(custom_indexes, &(&1.fields == [:optional_author_id]))
    required_index = Enum.find(custom_indexes, &(&1.fields == [:required_author_id]))

    assert optional_index.where == "optional_author_id IS NOT NULL"
    assert is_nil(required_index.where)
  end
end
