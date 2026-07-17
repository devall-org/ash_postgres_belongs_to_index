defmodule AshPostgresBelongsToIndex.TransformerTest do
  use ExUnit.Case, async: true

  alias AshPostgresBelongsToIndex.Transformer
  alias Spark.Dsl.Transformer, as: DslTransformer

  describe "transformer behavior" do
    test "creates indexed references for resources without manual references" do
      # Define a simple resource without manual references
      defmodule SimpleResource do
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshPostgresBelongsToIndex],
          validate_domain_inclusion?: false

        postgres do
          table "simple_resource"
          repo AshPostgresBelongsToIndex.Test.Support.TestResources.TestRepo
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string
        end

        relationships do
          belongs_to :company,
                     AshPostgresBelongsToIndex.Test.Support.TestResources.CompanyResource

          belongs_to :user, AshPostgresBelongsToIndex.Test.Support.TestResources.UserResource
        end
      end

      dsl_state = SimpleResource.spark_dsl_config()
      {:ok, transformed_state} = Transformer.transform(dsl_state)

      # Should create indexed references, not custom indexes
      references = DslTransformer.get_entities(transformed_state, [:postgres, :references])

      custom_indexes =
        DslTransformer.get_entities(transformed_state, [:postgres, :custom_indexes])

      # Should have references with index?: true
      assert length(references) == 2
      company_ref = Enum.find(references, &(&1.relationship == :company))
      user_ref = Enum.find(references, &(&1.relationship == :user))

      assert company_ref.index? == true
      assert user_ref.index? == true

      # Should not create custom indexes
      assert length(custom_indexes) == 0
    end

    test "creates custom indexes for resources with existing manual references" do
      # Define a resource with manual references (no index?)
      defmodule ResourceWithManualRefs do
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshPostgresBelongsToIndex],
          validate_domain_inclusion?: false

        postgres do
          table "resource_with_manual_refs"
          repo AshPostgresBelongsToIndex.Test.Support.TestResources.TestRepo

          references do
            reference :company, on_delete: :delete
            reference :user, on_delete: :nilify
          end
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string
        end

        relationships do
          belongs_to :company,
                     AshPostgresBelongsToIndex.Test.Support.TestResources.CompanyResource

          belongs_to :user, AshPostgresBelongsToIndex.Test.Support.TestResources.UserResource
          belongs_to :depot, AshPostgresBelongsToIndex.Test.Support.TestResources.DepotResource
        end
      end

      dsl_state = ResourceWithManualRefs.spark_dsl_config()
      {:ok, transformed_state} = Transformer.transform(dsl_state)

      references = DslTransformer.get_entities(transformed_state, [:postgres, :references])

      custom_indexes =
        DslTransformer.get_entities(transformed_state, [:postgres, :custom_indexes])

      # Should keep original manual references unchanged
      # 2 original + 1 new for depot
      assert length(references) == 3

      # Should create custom indexes for company and user (which have manual refs)
      company_index = Enum.find(custom_indexes, &(&1.fields == [:company_id]))
      user_index = Enum.find(custom_indexes, &(&1.fields == [:user_id]))

      assert company_index != nil
      assert user_index != nil

      # Should create indexed reference for depot (which doesn't have manual ref)
      depot_ref = Enum.find(references, &(&1.relationship == :depot))
      assert depot_ref.index? == true
    end

    test "handles multitenant resources correctly" do
      # Define a multitenant resource
      defmodule MultitenantResource do
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshPostgresBelongsToIndex],
          validate_domain_inclusion?: false

        postgres do
          table "multitenant_resource"
          repo AshPostgresBelongsToIndex.Test.Support.TestResources.TestRepo

          references do
            reference :company, on_delete: :delete
          end
        end

        multitenancy do
          strategy :attribute
          attribute :company_id
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string
        end

        relationships do
          belongs_to :company,
                     AshPostgresBelongsToIndex.Test.Support.TestResources.CompanyResource

          belongs_to :user, AshPostgresBelongsToIndex.Test.Support.TestResources.UserResource
          belongs_to :depot, AshPostgresBelongsToIndex.Test.Support.TestResources.DepotResource
        end
      end

      dsl_state = MultitenantResource.spark_dsl_config()
      {:ok, transformed_state} = Transformer.transform(dsl_state)

      custom_indexes =
        DslTransformer.get_entities(transformed_state, [:postgres, :custom_indexes])

      references = DslTransformer.get_entities(transformed_state, [:postgres, :references])

      # Company should NOT get a separate single-column index because the indexed
      # references for user and depot already create indexes starting with company_id
      # (e.g., [:company_id, :user_id]) which can satisfy FK lookups via leftmost prefix.
      company_index =
        Enum.find(custom_indexes, fn index ->
          index.fields == [:company_id]
        end)

      assert company_index == nil

      # Should NOT create redundant composite index [:company_id, :company_id]
      redundant_company_index =
        Enum.find(custom_indexes, fn index ->
          index.fields == [:company_id, :company_id]
        end)

      assert redundant_company_index == nil

      # User and depot should get indexed references (no manual refs)
      user_ref = Enum.find(references, &(&1.relationship == :user))
      depot_ref = Enum.find(references, &(&1.relationship == :depot))

      assert user_ref.index? == true
      assert depot_ref.index? == true

      # Should also create single-column custom indexes for multitenant FK enforcement
      user_single_index = Enum.find(custom_indexes, &(&1.fields == [:user_id]))
      depot_single_index = Enum.find(custom_indexes, &(&1.fields == [:depot_id]))

      assert user_single_index != nil
      assert depot_single_index != nil

      assert user_single_index.all_tenants? == true
      assert depot_single_index.all_tenants? == true
      assert user_single_index.include_base_filter? == false
      assert depot_single_index.include_base_filter? == false
      assert user_single_index.name == "multitenant_resource_user_id_fkey_index"
      assert depot_single_index.name == "multitenant_resource_depot_id_fkey_index"
    end

    test "respects except list configuration" do
      # Define a resource with except configuration
      defmodule ResourceWithExcept do
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshPostgresBelongsToIndex],
          validate_domain_inclusion?: false

        postgres do
          table "resource_with_except"
          repo AshPostgresBelongsToIndex.Test.Support.TestResources.TestRepo
        end

        postgres_belongs_to_index do
          except [:user]
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string
        end

        relationships do
          belongs_to :company,
                     AshPostgresBelongsToIndex.Test.Support.TestResources.CompanyResource

          belongs_to :user, AshPostgresBelongsToIndex.Test.Support.TestResources.UserResource
          belongs_to :depot, AshPostgresBelongsToIndex.Test.Support.TestResources.DepotResource
        end
      end

      dsl_state = ResourceWithExcept.spark_dsl_config()
      {:ok, transformed_state} = Transformer.transform(dsl_state)

      references = DslTransformer.get_entities(transformed_state, [:postgres, :references])

      # Should create references for company and depot, but not user
      company_ref = Enum.find(references, &(&1.relationship == :company))
      depot_ref = Enum.find(references, &(&1.relationship == :depot))
      user_ref = Enum.find(references, &(&1.relationship == :user))

      assert company_ref.index? == true
      assert depot_ref.index? == true
      # Should be excluded
      assert user_ref == nil
    end

    test "skips relationships that already have indexed references" do
      # Define a resource with an already indexed reference
      defmodule ResourceWithIndexedRef do
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshPostgresBelongsToIndex],
          validate_domain_inclusion?: false

        postgres do
          table "resource_with_indexed_ref"
          repo AshPostgresBelongsToIndex.Test.Support.TestResources.TestRepo

          references do
            reference :company, on_delete: :delete, index?: true
          end
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string
        end

        relationships do
          belongs_to :company,
                     AshPostgresBelongsToIndex.Test.Support.TestResources.CompanyResource

          belongs_to :user, AshPostgresBelongsToIndex.Test.Support.TestResources.UserResource
        end
      end

      dsl_state = ResourceWithIndexedRef.spark_dsl_config()
      {:ok, transformed_state} = Transformer.transform(dsl_state)

      references = DslTransformer.get_entities(transformed_state, [:postgres, :references])

      custom_indexes =
        DslTransformer.get_entities(transformed_state, [:postgres, :custom_indexes])

      # Should have 2 references: original company + new user
      assert length(references) == 2

      # Company should keep its existing indexed reference
      company_refs = Enum.filter(references, &(&1.relationship == :company))
      assert length(company_refs) == 1
      assert hd(company_refs).index? == true

      # User should get new indexed reference
      user_ref = Enum.find(references, &(&1.relationship == :user))
      assert user_ref.index? == true

      # Should not create any custom indexes
      assert length(custom_indexes) == 0
    end

    test "detects existing custom indexes and skips FK coverage" do
      # Define a resource with existing custom index covering FK
      defmodule ResourceWithCustomIndex do
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshPostgresBelongsToIndex],
          validate_domain_inclusion?: false

        postgres do
          table "resource_with_custom_index"
          repo AshPostgresBelongsToIndex.Test.Support.TestResources.TestRepo

          custom_indexes do
            # Covers company FK
            index [:company_id]
          end
        end

        multitenancy do
          strategy :attribute
          attribute :company_id
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string
        end

        relationships do
          belongs_to :company,
                     AshPostgresBelongsToIndex.Test.Support.TestResources.CompanyResource

          belongs_to :user, AshPostgresBelongsToIndex.Test.Support.TestResources.UserResource
        end
      end

      dsl_state = ResourceWithCustomIndex.spark_dsl_config()
      {:ok, transformed_state} = Transformer.transform(dsl_state)

      references = DslTransformer.get_entities(transformed_state, [:postgres, :references])

      custom_indexes =
        DslTransformer.get_entities(transformed_state, [:postgres, :custom_indexes])

      # Should only create reference for user (company already covered by custom index)
      user_ref = Enum.find(references, &(&1.relationship == :user))
      company_ref = Enum.find(references, &(&1.relationship == :company))

      assert user_ref.index? == true
      # Should not create reference for company
      assert company_ref == nil

      # Should have original custom index + no new ones for company
      company_indexes =
        Enum.filter(custom_indexes, fn index ->
          index.fields == [:company_id] or index.fields == [:company_id, :company_id]
        end)

      # Only the original
      assert length(company_indexes) == 1

      # Should also create single-column custom index for user FK enforcement
      user_single_index = Enum.find(custom_indexes, &(&1.fields == [:user_id]))
      assert user_single_index != nil
    end

    test "handles non-multitenant resources correctly" do
      # Define a non-multitenant resource
      defmodule NonMultitenantResource do
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshPostgresBelongsToIndex],
          validate_domain_inclusion?: false

        postgres do
          table "non_multitenant_resource"
          repo AshPostgresBelongsToIndex.Test.Support.TestResources.TestRepo

          references do
            reference :company, on_delete: :delete
          end
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string
        end

        relationships do
          belongs_to :company,
                     AshPostgresBelongsToIndex.Test.Support.TestResources.CompanyResource

          belongs_to :user, AshPostgresBelongsToIndex.Test.Support.TestResources.UserResource
        end
      end

      dsl_state = NonMultitenantResource.spark_dsl_config()
      {:ok, transformed_state} = Transformer.transform(dsl_state)

      custom_indexes =
        DslTransformer.get_entities(transformed_state, [:postgres, :custom_indexes])

      references = DslTransformer.get_entities(transformed_state, [:postgres, :references])

      # Company should get simple custom index (no tenant prefix)
      company_index = Enum.find(custom_indexes, &(&1.fields == [:company_id]))
      assert company_index != nil

      # User should get indexed reference
      user_ref = Enum.find(references, &(&1.relationship == :user))
      assert user_ref.index? == true
    end
  end

  describe "multitenant resource tests" do
    test "creates indexed references for multitenant resource without manual references" do
      # Test the dedicated multitenant resource
      dsl_state =
        AshPostgresBelongsToIndex.Test.Support.TestResources.MultitenantOrderResource.spark_dsl_config()

      {:ok, transformed_state} = Transformer.transform(dsl_state)

      references = DslTransformer.get_entities(transformed_state, [:postgres, :references])

      custom_indexes =
        DslTransformer.get_entities(transformed_state, [:postgres, :custom_indexes])

      # Should create indexed references for user and depot (no manual refs)
      user_ref = Enum.find(references, &(&1.relationship == :user))
      depot_ref = Enum.find(references, &(&1.relationship == :depot))

      assert user_ref.index? == true
      assert depot_ref.index? == true

      # Company relationship should NOT get an indexed reference (source_attr == tenant_attr)
      company_ref = Enum.find(references, &(&1.relationship == :company))
      assert company_ref == nil

      # Should create single-column custom indexes for user and depot only.
      # Company does NOT need a separate index because the user/depot indexed references
      # already create indexes starting with company_id (leftmost prefix rule).
      assert length(custom_indexes) == 2

      company_single_index = Enum.find(custom_indexes, &(&1.fields == [:company_id]))
      user_single_index = Enum.find(custom_indexes, &(&1.fields == [:user_id]))
      depot_single_index = Enum.find(custom_indexes, &(&1.fields == [:depot_id]))

      assert company_single_index == nil
      assert user_single_index != nil
      assert depot_single_index != nil

      assert user_single_index.all_tenants? == true
      assert depot_single_index.all_tenants? == true
    end

    test "creates custom indexes for multitenant resource with manual references" do
      # Test the dedicated multitenant resource with manual references
      dsl_state =
        AshPostgresBelongsToIndex.Test.Support.TestResources.MultitenantOrderWithRefsResource.spark_dsl_config()

      {:ok, transformed_state} = Transformer.transform(dsl_state)

      references = DslTransformer.get_entities(transformed_state, [:postgres, :references])

      custom_indexes =
        DslTransformer.get_entities(transformed_state, [:postgres, :custom_indexes])

      # Should have original manual references + new indexed reference for depot
      depot_ref = Enum.find(references, &(&1.relationship == :depot))
      assert depot_ref.index? == true

      # Should create composite custom index for user (has manual ref but no index?)
      user_composite_index = Enum.find(custom_indexes, &(&1.fields == [:company_id, :user_id]))
      assert user_composite_index != nil

      # Should also create single-column custom indexes for multitenant FK enforcement
      user_single_index = Enum.find(custom_indexes, &(&1.fields == [:user_id]))
      depot_single_index = Enum.find(custom_indexes, &(&1.fields == [:depot_id]))

      assert user_single_index != nil
      assert depot_single_index != nil

      assert user_single_index.all_tenants? == true
      assert depot_single_index.all_tenants? == true

      # Company should NOT get a separate single-column index because other
      # relationships create indexes starting with company_id (leftmost prefix rule)
      company_single_index =
        Enum.find(custom_indexes, fn index ->
          index.fields == [:company_id]
        end)

      assert company_single_index == nil

      # Should NOT create redundant composite index [:company_id, :company_id]
      redundant_company_index =
        Enum.find(custom_indexes, fn index ->
          index.fields == [:company_id, :company_id]
        end)

      assert redundant_company_index == nil
    end

    test "verifies composite index structure for multitenant resources" do
      # Test that multitenant resources create proper composite indexes
      dsl_state =
        AshPostgresBelongsToIndex.Test.Support.TestResources.MultitenantOrderWithRefsResource.spark_dsl_config()

      {:ok, transformed_state} = Transformer.transform(dsl_state)

      custom_indexes =
        DslTransformer.get_entities(transformed_state, [:postgres, :custom_indexes])

      # User index should be composite: [:company_id, :user_id]
      user_index = Enum.find(custom_indexes, &(&1.fields == [:company_id, :user_id]))
      assert user_index != nil
      assert user_index.fields == [:company_id, :user_id]

      # Should also create single-column indexes for multitenant FK enforcement
      simple_user_index = Enum.find(custom_indexes, &(&1.fields == [:user_id]))
      assert simple_user_index != nil
      assert simple_user_index.all_tenants? == true
    end
  end

  describe "multitenancy index prefixing" do
    test "creates single-column index when non-all_tenants index exists on same field" do
      defmodule MultitenantWithNonAllTenantsIndex do
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshPostgresBelongsToIndex],
          validate_domain_inclusion?: false

        postgres do
          table "mt_with_non_all_tenants_index"
          repo AshPostgresBelongsToIndex.Test.Support.TestResources.TestRepo

          custom_indexes do
            index [:depot_id]
          end
        end

        multitenancy do
          strategy :attribute
          attribute :company_id
        end

        attributes do
          uuid_primary_key :id
        end

        relationships do
          belongs_to :company,
                     AshPostgresBelongsToIndex.Test.Support.TestResources.CompanyResource

          belongs_to :depot, AshPostgresBelongsToIndex.Test.Support.TestResources.DepotResource
        end
      end

      dsl_state = MultitenantWithNonAllTenantsIndex.spark_dsl_config()
      {:ok, transformed_state} = Transformer.transform(dsl_state)

      custom_indexes =
        DslTransformer.get_entities(transformed_state, [:postgres, :custom_indexes])

      # The user-defined `index [:depot_id]` (without all_tenants?) will effectively be
      # [:company_id, :depot_id] in the database due to tenant prefixing.
      # So the plugin should STILL create a single-column [:depot_id] with all_tenants?: true
      depot_single_index =
        Enum.find(custom_indexes, fn idx ->
          idx.fields == [:depot_id] && idx.all_tenants? == true
        end)

      assert depot_single_index != nil
    end

    test "recognizes non-all_tenants index as effective composite and does not duplicate it" do
      defmodule MultitenantWithEffectiveComposite do
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshPostgresBelongsToIndex],
          validate_domain_inclusion?: false

        postgres do
          table "mt_with_effective_composite"
          repo AshPostgresBelongsToIndex.Test.Support.TestResources.TestRepo

          custom_indexes do
            index [:depot_id]
          end

          references do
            reference :depot, on_delete: :delete
          end
        end

        multitenancy do
          strategy :attribute
          attribute :company_id
        end

        attributes do
          uuid_primary_key :id
        end

        relationships do
          belongs_to :company,
                     AshPostgresBelongsToIndex.Test.Support.TestResources.CompanyResource

          belongs_to :depot, AshPostgresBelongsToIndex.Test.Support.TestResources.DepotResource
        end
      end

      dsl_state = MultitenantWithEffectiveComposite.spark_dsl_config()
      {:ok, transformed_state} = Transformer.transform(dsl_state)

      custom_indexes =
        DslTransformer.get_entities(transformed_state, [:postgres, :custom_indexes])

      # The user-defined `index [:depot_id]` (without all_tenants?) effectively creates
      # [:company_id, :depot_id] in the DB. The plugin should NOT create a duplicate
      # explicit composite [:company_id, :depot_id] index.
      explicit_composite =
        Enum.find(custom_indexes, fn idx ->
          idx.fields == [:company_id, :depot_id]
        end)

      assert explicit_composite == nil

      # Should still create single-column [:depot_id] with all_tenants?: true
      depot_single =
        Enum.find(custom_indexes, fn idx ->
          idx.fields == [:depot_id] && idx.all_tenants? == true
        end)

      assert depot_single != nil
    end

    test "composite index added via manual-ref path does not set all_tenants?" do
      defmodule MultitenantManualRefComposite do
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshPostgresBelongsToIndex],
          validate_domain_inclusion?: false

        postgres do
          table "mt_manual_ref_composite"
          repo AshPostgresBelongsToIndex.Test.Support.TestResources.TestRepo

          references do
            reference :user, on_delete: :nilify
          end
        end

        multitenancy do
          strategy :attribute
          attribute :company_id
        end

        attributes do
          uuid_primary_key :id
        end

        relationships do
          belongs_to :company,
                     AshPostgresBelongsToIndex.Test.Support.TestResources.CompanyResource

          belongs_to :user, AshPostgresBelongsToIndex.Test.Support.TestResources.UserResource
        end
      end

      dsl_state = MultitenantManualRefComposite.spark_dsl_config()
      {:ok, transformed_state} = Transformer.transform(dsl_state)

      custom_indexes =
        DslTransformer.get_entities(transformed_state, [:postgres, :custom_indexes])

      # The plugin creates composite [:company_id, :user_id] via manual-ref path.
      # It does NOT set all_tenants? because Enum.uniq in index_keys already
      # prevents double-prefixing. Not setting it avoids snapshot diff noise.
      composite_index =
        Enum.find(custom_indexes, fn idx ->
          idx.fields == [:company_id, :user_id]
        end)

      assert composite_index != nil
      refute composite_index.all_tenants?
    end
  end

  describe "company-only resources" do
    test "creates single-column company_id index when no other relationships exist" do
      # This tests resources like custom_zones and pods that ONLY have belongs_to :company
      # Since there are no other relationships to create indexed references,
      # we need an explicit [:company_id] index for FK enforcement.
      defmodule CompanyOnlyResource do
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshPostgresBelongsToIndex],
          validate_domain_inclusion?: false

        postgres do
          table "company_only_resource"
          repo AshPostgresBelongsToIndex.Test.Support.TestResources.TestRepo
        end

        multitenancy do
          strategy :attribute
          attribute :company_id
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string
        end

        relationships do
          belongs_to :company,
                     AshPostgresBelongsToIndex.Test.Support.TestResources.CompanyResource
        end
      end

      dsl_state = CompanyOnlyResource.spark_dsl_config()
      {:ok, transformed_state} = Transformer.transform(dsl_state)

      custom_indexes =
        DslTransformer.get_entities(transformed_state, [:postgres, :custom_indexes])

      references = DslTransformer.get_entities(transformed_state, [:postgres, :references])

      # No indexed references should be created (company relationship skips composite)
      assert Enum.empty?(references)

      # SHOULD create single-column [:company_id] index because no other index covers it
      company_index = Enum.find(custom_indexes, &(&1.fields == [:company_id]))
      assert company_index != nil
      assert company_index.all_tenants? == true
    end
  end

  describe "covering composite custom indexes (leftmost prefix rule)" do
    test "non-multitenant: custom index with trailing columns covers the FK" do
      defmodule NonMtCoveringComposite do
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshPostgresBelongsToIndex],
          validate_domain_inclusion?: false

        postgres do
          table "non_mt_covering_composite"
          repo AshPostgresBelongsToIndex.Test.Support.TestResources.TestRepo

          custom_indexes do
            index [:company_id, :inserted_at]
          end
        end

        attributes do
          uuid_primary_key :id
          create_timestamp :inserted_at
        end

        relationships do
          belongs_to :company,
                     AshPostgresBelongsToIndex.Test.Support.TestResources.CompanyResource
        end
      end

      dsl_state = NonMtCoveringComposite.spark_dsl_config()
      {:ok, transformed_state} = Transformer.transform(dsl_state)

      references = DslTransformer.get_entities(transformed_state, [:postgres, :references])

      custom_indexes =
        DslTransformer.get_entities(transformed_state, [:postgres, :custom_indexes])

      # [:company_id, :inserted_at] already covers company_id lookups,
      # so no indexed reference or extra index should be added
      assert references == []
      assert Enum.map(custom_indexes, & &1.fields) == [[:company_id, :inserted_at]]
    end

    test "multitenant: custom index with trailing columns covers the composite" do
      defmodule MtCoveringComposite do
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshPostgresBelongsToIndex],
          validate_domain_inclusion?: false

        postgres do
          table "mt_covering_composite"
          repo AshPostgresBelongsToIndex.Test.Support.TestResources.TestRepo

          custom_indexes do
            # Effectively [:company_id, :user_id, :inserted_at] due to tenant prefixing
            index [:user_id, :inserted_at]
          end
        end

        multitenancy do
          strategy :attribute
          attribute :company_id
        end

        attributes do
          uuid_primary_key :id
          create_timestamp :inserted_at
        end

        relationships do
          belongs_to :company,
                     AshPostgresBelongsToIndex.Test.Support.TestResources.CompanyResource

          belongs_to :user, AshPostgresBelongsToIndex.Test.Support.TestResources.UserResource
        end
      end

      dsl_state = MtCoveringComposite.spark_dsl_config()
      {:ok, transformed_state} = Transformer.transform(dsl_state)

      references = DslTransformer.get_entities(transformed_state, [:postgres, :references])

      custom_indexes =
        DslTransformer.get_entities(transformed_state, [:postgres, :custom_indexes])

      # The effective [:company_id, :user_id, :inserted_at] covers [:company_id, :user_id],
      # so no indexed reference should be added for user
      assert references == []

      # It also covers company_id as leftmost, so no single [:company_id] index.
      # It does NOT cover user_id-only lookups (user_id is not leftmost),
      # so the single-column [:user_id] all_tenants? index is still needed.
      assert Enum.map(custom_indexes, &{&1.fields, &1.all_tenants?}) == [
               {[:user_id, :inserted_at], false},
               {[:user_id], true}
             ]
    end

    test "partial custom index with unrelated where clause does not count as covering" do
      defmodule PartialUnrelatedWhere do
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshPostgresBelongsToIndex],
          validate_domain_inclusion?: false

        postgres do
          table "partial_unrelated_where"
          repo AshPostgresBelongsToIndex.Test.Support.TestResources.TestRepo

          custom_indexes do
            index [:company_id], where: "deleted_at IS NULL"
          end
        end

        attributes do
          uuid_primary_key :id
          attribute :deleted_at, :utc_datetime_usec
        end

        relationships do
          belongs_to :company,
                     AshPostgresBelongsToIndex.Test.Support.TestResources.CompanyResource
        end
      end

      dsl_state = PartialUnrelatedWhere.spark_dsl_config()
      {:ok, transformed_state} = Transformer.transform(dsl_state)

      references = DslTransformer.get_entities(transformed_state, [:postgres, :references])

      # The partial index excludes rows where deleted_at is set, so it cannot
      # serve general FK lookups — an indexed reference must still be added
      company_ref = Enum.find(references, &(&1.relationship == :company))
      assert company_ref.index? == true
    end

    test "partial custom index on the FK's own IS NOT NULL counts as covering" do
      defmodule PartialNotNilWhere do
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshPostgresBelongsToIndex],
          validate_domain_inclusion?: false

        postgres do
          table "partial_not_nil_where"
          repo AshPostgresBelongsToIndex.Test.Support.TestResources.TestRepo

          custom_indexes do
            index [:company_id], where: "company_id IS NOT NULL"
          end
        end

        attributes do
          uuid_primary_key :id
        end

        relationships do
          belongs_to :company,
                     AshPostgresBelongsToIndex.Test.Support.TestResources.CompanyResource
        end
      end

      dsl_state = PartialNotNilWhere.spark_dsl_config()
      {:ok, transformed_state} = Transformer.transform(dsl_state)

      references = DslTransformer.get_entities(transformed_state, [:postgres, :references])

      # FK lookups are equality on company_id, which implies IS NOT NULL,
      # so this partial index covers them — no extra reference needed
      assert references == []
    end
  end
end
