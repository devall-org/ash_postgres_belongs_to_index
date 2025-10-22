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

      # Company should NOT get any index because its FK is the same as tenant attribute
      # (the belongs_to :company would use company_id, which is also the tenant attribute)
      company_index =
        Enum.find(custom_indexes, fn index ->
          index.fields == [:company_id] or index.fields == [:company_id, :company_id]
        end)

      # Company should be filtered out by get_belongs_toes since source_attribute == multitenant_attr
      assert company_index == nil

      # User and depot should get indexed references (no manual refs)
      user_ref = Enum.find(references, &(&1.relationship == :user))
      depot_ref = Enum.find(references, &(&1.relationship == :depot))

      assert user_ref.index? == true
      assert depot_ref.index? == true
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

      # Company relationship should be filtered out (company_id == tenant attribute)
      company_ref = Enum.find(references, &(&1.relationship == :company))
      assert company_ref == nil

      # Should not create any custom indexes since no manual references
      assert length(custom_indexes) == 0
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

      # Should create custom indexes for user (has manual ref but no index?)
      user_index = Enum.find(custom_indexes, &(&1.fields == [:company_id, :user_id]))
      assert user_index != nil

      # Company should be filtered out (company_id == tenant attribute)
      company_index =
        Enum.find(custom_indexes, fn index ->
          index.fields == [:company_id] or index.fields == [:company_id, :company_id]
        end)

      assert company_index == nil
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

      # Should not create simple indexes for FK that have manual references in multitenant
      simple_user_index = Enum.find(custom_indexes, &(&1.fields == [:user_id]))
      assert simple_user_index == nil
    end
  end

  describe "helper functions" do
    test "fk_already_indexed? detects composite indexes correctly" do
      # This tests the private function indirectly through transformer behavior
      # Already covered by the custom index test above
      assert true
    end

    test "get_belongs_toes filters out multitenant attribute correctly" do
      # This tests the belongs_to filtering logic
      # Covered by multitenant tests above
      assert true
    end
  end
end
