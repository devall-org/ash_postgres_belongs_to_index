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
    |> add_missing_indexes(dsl_state, manual_references, multitenant_attr)
    |> then(&{:ok, &1})
  end

  def get_belongs_toes(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:relationships])
    |> Enum.filter(fn
      %BelongsTo{} -> true
      %{} -> false
    end)
  end

  defp reject_excluded_relationships(belongs_tos, except_list) do
    Enum.reject(belongs_tos, fn %BelongsTo{name: name} -> name in except_list end)
  end

  defp has_indexed_manual_reference?(relationship_name, manual_references) do
    Enum.any?(manual_references, fn ref ->
      ref.relationship == relationship_name && ref.index? == true
    end)
  end

  # A custom index covers the given fields when its effective fields start with
  # them (leftmost prefix rule), e.g. [:fk_id, :created_at] covers [:fk_id].
  # A partial index only counts when its condition is implied by the lookups we
  # care about: FK lookups are equality on the last field, which implies
  # "last_field IS NOT NULL". Any other predicate may exclude matching rows.
  defp has_custom_index_on?(dsl_state, effective_fields, multitenant_attr) do
    dsl_state
    |> Transformer.get_entities([:postgres, :custom_indexes])
    |> Enum.any?(fn idx ->
      idx |> effective_index_fields(multitenant_attr) |> List.starts_with?(effective_fields) &&
        (is_nil(idx.where) || idx.where == "#{List.last(effective_fields)} IS NOT NULL")
    end)
  end

  defp effective_index_fields(idx, multitenant_attr) do
    fields = idx.fields || []

    case {multitenant_attr, idx.all_tenants?} do
      {nil, _} -> fields
      {_, true} -> fields
      {tenant_attr, _} -> Enum.uniq([tenant_attr | fields])
    end
  end

  defp add_missing_indexes(belongs_tos, dsl_state, manual_references, multitenant_attr) do
    # First pass: add composite indexes for non-tenant relationships
    dsl_state =
      Enum.reduce(belongs_tos, dsl_state, fn belongs_to, acc ->
        add_composite_index_for_relationship(belongs_to, acc, manual_references, multitenant_attr)
      end)

    # Second pass: add single-column indexes where needed
    Enum.reduce(belongs_tos, dsl_state, fn belongs_to, acc ->
      add_single_column_index_for_relationship(belongs_to, acc, multitenant_attr)
    end)
  end

  defp add_composite_index_for_relationship(
         %BelongsTo{name: name, source_attribute: source_attr, allow_nil?: allow_nil?},
         dsl_state,
         manual_references,
         multitenant_attr
       ) do
    # Skip composite index if source_attr == tenant_attr (would be redundant [:company_id, :company_id])
    if source_attr == multitenant_attr do
      dsl_state
    else
      has_manual_ref = has_manual_reference?(name, manual_references)

      ensure_composite_index(
        dsl_state,
        name,
        source_attr,
        multitenant_attr,
        has_manual_ref,
        manual_references,
        allow_nil?
      )
    end
  end

  defp add_single_column_index_for_relationship(
         %BelongsTo{source_attribute: source_attr, allow_nil?: allow_nil?},
         dsl_state,
         multitenant_attr
       ) do
    ensure_single_column_index(dsl_state, source_attr, multitenant_attr, allow_nil?)
  end

  defp ensure_composite_index(
         dsl_state,
         name,
         source_attr,
         multitenant_attr,
         has_manual_ref,
         manual_references,
         allow_nil?
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
          add_custom_index(dsl_state, composite_fields, partial_opts(source_attr, allow_nil?))

        false ->
          add_indexed_reference(dsl_state, name, allow_nil?)
      end
    end
  end

  defp ensure_single_column_index(dsl_state, _source_attr, nil, _allow_nil?), do: dsl_state

  defp ensure_single_column_index(dsl_state, source_attr, tenant_attr, allow_nil?) do
    # Only create single-column index if no existing index covers this column
    # as the leftmost field (which can satisfy FK lookups via prefix rule)
    if has_index_starting_with?(dsl_state, source_attr, tenant_attr) do
      dsl_state
    else
      add_custom_index(
        dsl_state,
        [source_attr],
        [
          all_tenants?: true,
          include_base_filter?: false,
          name: foreign_key_index_name(dsl_state, source_attr)
        ] ++ partial_opts(source_attr, allow_nil?)
      )
    end
  end

  # Nullable FKs get partial indexes: FK lookups always match non-NULL values,
  # so excluding NULL rows keeps the index smaller at no cost.
  defp partial_opts(_source_attr, false), do: []
  defp partial_opts(source_attr, true), do: [where: "#{source_attr} IS NOT NULL"]

  defp has_index_starting_with?(dsl_state, field, multitenant_attr) do
    has_custom_index_on?(dsl_state, [field], multitenant_attr) ||
      has_indexed_reference_starting_with?(dsl_state, field, multitenant_attr)
  end

  defp has_indexed_reference_starting_with?(dsl_state, field, multitenant_attr) do
    # Indexed references create composite indexes starting with tenant_attr (if multitenant)
    # or with the FK column (if non-multitenant)
    case multitenant_attr do
      nil ->
        false

      tenant_attr ->
        # If looking for tenant_attr and there's any indexed reference, it will start with
        # tenant_attr. Partial reference indexes (index_where on the FK column) don't count:
        # they exclude rows where that FK is NULL, so they can't serve tenant-only lookups.
        field == tenant_attr &&
          dsl_state
          |> Transformer.get_entities([:postgres, :references])
          |> Enum.any?(&(&1.index? && is_nil(Map.get(&1, :index_where))))
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

  defp add_indexed_reference(dsl_state, relationship_name, allow_nil?) do
    reference_opts = [relationship: relationship_name, index?: true]

    reference_opts =
      if allow_nil? do
        Keyword.put(reference_opts, :index_where, :not_nil)
      else
        reference_opts
      end

    {:ok, reference} =
      Transformer.build_entity(
        AshPostgres.DataLayer,
        [:postgres, :references],
        :reference,
        reference_opts
      )

    Transformer.add_entity(dsl_state, [:postgres, :references], reference, type: :append)
  end

  defp build_index_fields(source_attr, nil), do: [source_attr]
  defp build_index_fields(source_attr, tenant_attr), do: [tenant_attr, source_attr]

  defp foreign_key_index_name(dsl_state, source_attr) do
    table = Transformer.get_option(dsl_state, [:postgres], :table)
    "#{table}_#{source_attr}_fkey_index"
  end
end
