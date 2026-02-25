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
    has_composite =
      has_indexed_manual_reference?(name, manual_references) ||
        has_custom_index_on?(dsl_state, build_index_fields(source_attr, multitenant_attr), multitenant_attr)

    has_single = has_custom_index_on?(dsl_state, [source_attr], multitenant_attr)

    case multitenant_attr do
      nil -> has_composite || has_single
      _tenant_attr -> has_composite && has_single
    end
  end

  defp has_indexed_manual_reference?(relationship_name, manual_references) do
    Enum.any?(manual_references, fn ref ->
      ref.relationship == relationship_name && ref.index? == true
    end)
  end

  defp has_custom_index_on?(dsl_state, effective_fields, multitenant_attr) do
    dsl_state
    |> Transformer.get_entities([:postgres, :custom_indexes])
    |> Enum.any?(fn idx ->
      effective_index_fields(idx, multitenant_attr) == effective_fields
    end)
  end

  defp effective_index_fields(idx, multitenant_attr) do
    fields = idx.fields || []

    case {multitenant_attr, idx.all_tenants?} do
      {nil, _} -> fields
      {_, true} -> fields
      {tenant_attr, _} -> [tenant_attr | fields]
    end
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
    has_manual_ref = has_manual_reference?(name, manual_references)

    dsl_state
    |> ensure_composite_index(name, source_attr, multitenant_attr, has_manual_ref, manual_references)
    |> ensure_single_column_index(source_attr, multitenant_attr)
  end

  defp ensure_composite_index(
         dsl_state,
         name,
         source_attr,
         multitenant_attr,
         has_manual_ref,
         manual_references
       ) do
    composite_fields = build_index_fields(source_attr, multitenant_attr)

    already_has_composite =
      has_custom_index_on?(dsl_state, composite_fields, multitenant_attr) ||
        has_indexed_manual_reference?(name, manual_references)

    if already_has_composite do
      dsl_state
    else
      case has_manual_ref do
        true ->
          opts = if multitenant_attr, do: [all_tenants?: true], else: []
          add_custom_index(dsl_state, composite_fields, opts)

        false ->
          add_indexed_reference(dsl_state, name)
      end
    end
  end

  defp ensure_single_column_index(dsl_state, _source_attr, nil), do: dsl_state

  defp ensure_single_column_index(dsl_state, source_attr, tenant_attr) do
    if has_custom_index_on?(dsl_state, [source_attr], tenant_attr) do
      dsl_state
    else
      add_custom_index(dsl_state, [source_attr], all_tenants?: true)
    end
  end

  defp has_manual_reference?(relationship_name, manual_references) do
    Enum.any?(manual_references, fn ref -> ref.relationship == relationship_name end)
  end

  defp add_custom_index(dsl_state, fields, opts) do
    {:ok, index} =
      Transformer.build_entity(
        AshPostgres.DataLayer,
        [:postgres, :custom_indexes],
        :index,
        Keyword.merge([fields: fields], opts)
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
end
