defmodule AshPostgresBelongsToIndex.Transformer do
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Ash.Resource.Relationships.BelongsTo

  def after?(Ash.Resource.Transformers.BelongsToAttribute), do: true
  def after?(_), do: false

  def transform(dsl_state) do
    table = dsl_state |> Transformer.get_option([:postgres], :table)
    except_list = Transformer.get_option(dsl_state, [:postgres_belongs_to_index], :except, [])

    dsl_state
    |> get_belongs_toes()
    |> Enum.reject(fn %BelongsTo{name: name} -> name in except_list end)
    |> Enum.reduce(dsl_state, fn %BelongsTo{name: name, source_attribute: attr}, dsl_state ->
      {:ok, index} =
        Transformer.build_entity(AshPostgres.DataLayer, [:postgres, :custom_indexes], :index,
          fields: [attr],
          name: "#{table}_belongs_to_#{name}_index"
        )

      dsl_state |> Transformer.add_entity([:postgres, :custom_indexes], index, type: :append)
    end)
    |> then(fn dsl_state -> {:ok, dsl_state} end)
  end

  def get_belongs_toes(dsl_state) do
    multitenant_attr = dsl_state |> Transformer.get_option([:multitenancy], :attribute)

    dsl_state
    |> Transformer.get_entities([:relationships])
    |> Enum.filter(fn
      %BelongsTo{source_attribute: source_attribute} -> source_attribute != multitenant_attr
      %{} -> false
    end)
  end
end
