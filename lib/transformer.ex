defmodule AshPostgresBelongsToIndex.Transformer do
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Ash.Resource.Relationships.BelongsTo

  def after?(Ash.Resource.Transformers.BelongsToAttribute), do: true
  def after?(_), do: false

  def transform(dsl_state) do
    except_list = Transformer.get_option(dsl_state, [:postgres_belongs_to_index], :except, [])
    multitenant_attr = Transformer.get_option(dsl_state, [:multitenancy], :attribute)
    manual_references = Transformer.get_entities(dsl_state, [:postgres, :references])

    dsl_state
    |> get_belongs_toes()
    |> reject_excluded_relationships(except_list)
    |> reject_already_indexed_relationships(dsl_state, manual_references, multitenant_attr)
    |> add_missing_indexes(dsl_state, manual_references, multitenant_attr)
    |> then(&{:ok, &1})
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

  defp reject_excluded_relationships(belongs_tos, except_list) do
    Enum.reject(belongs_tos, fn %BelongsTo{name: name} -> name in except_list end)
  end

  defp reject_already_indexed_relationships(
         belongs_tos,
         dsl_state,
         manual_references,
         multitenant_attr
       ) do
    Enum.reject(
      belongs_tos,
      &already_indexed?(&1, dsl_state, manual_references, multitenant_attr)
    )
  end

  defp already_indexed?(
         %BelongsTo{name: name, source_attribute: source_attr},
         dsl_state,
         manual_references,
         multitenant_attr
       ) do
    has_indexed_manual_reference?(name, manual_references) ||
      has_existing_custom_index?(dsl_state, source_attr, multitenant_attr)
  end

  defp has_indexed_manual_reference?(relationship_name, manual_references) do
    Enum.any?(manual_references, fn ref ->
      ref.relationship == relationship_name && ref.index? == true
    end)
  end

  defp has_existing_custom_index?(dsl_state, fk_attribute, multitenant_attr) do
    dsl_state
    |> Transformer.get_entities([:postgres, :custom_indexes])
    |> Enum.any?(&index_covers_fk?(&1, fk_attribute, multitenant_attr))
  end

  defp add_missing_indexes(belongs_tos, dsl_state, manual_references, multitenant_attr) do
    Enum.reduce(belongs_tos, dsl_state, fn belongs_to, acc_dsl_state ->
      add_index_for_relationship(belongs_to, acc_dsl_state, manual_references, multitenant_attr)
    end)
  end

  defp add_index_for_relationship(
         %BelongsTo{name: name, source_attribute: source_attr},
         dsl_state,
         manual_references,
         multitenant_attr
       ) do
    case has_manual_reference?(name, manual_references) do
      true -> add_custom_index(dsl_state, source_attr, multitenant_attr)
      false -> add_indexed_reference(dsl_state, name)
    end
  end

  defp has_manual_reference?(relationship_name, manual_references) do
    Enum.any?(manual_references, fn ref -> ref.relationship == relationship_name end)
  end

  defp add_custom_index(dsl_state, source_attr, multitenant_attr) do
    index_fields = build_index_fields(source_attr, multitenant_attr)

    {:ok, index} =
      Transformer.build_entity(
        AshPostgres.DataLayer,
        [:postgres, :custom_indexes],
        :index,
        fields: index_fields
      )

    Transformer.add_entity(dsl_state, [:postgres, :custom_indexes], index, type: :append)
  end

  defp add_indexed_reference(dsl_state, relationship_name) do
    {:ok, reference} =
      Transformer.build_entity(
        AshPostgres.DataLayer,
        [:postgres, :references],
        :reference,
        relationship: relationship_name,
        index?: true
      )

    Transformer.add_entity(dsl_state, [:postgres, :references], reference, type: :append)
  end

  defp build_index_fields(source_attr, nil), do: [source_attr]
  defp build_index_fields(source_attr, tenant_attr), do: [tenant_attr, source_attr]

  defp index_covers_fk?(index, fk_attribute, multitenant_attr) do
    index_columns = index.fields || []

    case multitenant_attr do
      nil ->
        index_columns == [fk_attribute]

      tenant_attr when is_atom(tenant_attr) ->
        # For multitenant resources, accept both composite [:tenant_id, :fk_id] and simple [:fk_id] indexes.
        # Simple indexes are acceptable because PostgreSQL can efficiently use composite indexes 
        # (like [:tenant_id, :fk_id]) for single-column queries on the first column, but existing
        # simple indexes may have been created for specific query patterns or before multitenancy.
        index_columns == [tenant_attr, fk_attribute] or index_columns == [fk_attribute]
    end
  end
end
