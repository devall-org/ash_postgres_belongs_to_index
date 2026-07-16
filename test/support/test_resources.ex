defmodule AshPostgresBelongsToIndex.Test.Support.TestResources do
  @moduledoc """
  Test helper resources for testing the transformer
  """

  defmodule TestRepo do
    @moduledoc false
    use AshPostgres.Repo,
      otp_app: :ash_postgres_belongs_to_index,
      warn_on_missing_ash_functions?: false

    def min_pg_version do
      %Version{major: 16, minor: 0, patch: 0}
    end
  end

  defmodule CompanyResource do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: AshPostgres.DataLayer,
      validate_domain_inclusion?: false

    postgres do
      table "companies"
      repo TestRepo
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string
    end
  end

  defmodule UserResource do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: AshPostgres.DataLayer,
      validate_domain_inclusion?: false

    postgres do
      table "users"
      repo TestRepo
    end

    attributes do
      uuid_primary_key :id
      attribute :email, :string
    end
  end

  defmodule DepotResource do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: AshPostgres.DataLayer,
      validate_domain_inclusion?: false

    postgres do
      table "depots"
      repo TestRepo
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string
    end
  end

  defmodule MultitenantOrderResource do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshPostgresBelongsToIndex],
      validate_domain_inclusion?: false

    postgres do
      table "multitenant_orders"
      repo TestRepo
    end

    multitenancy do
      strategy :attribute
      attribute :company_id
    end

    attributes do
      uuid_primary_key :id
      attribute :order_number, :string
    end

    relationships do
      belongs_to :company, CompanyResource
      belongs_to :user, UserResource
      belongs_to :depot, DepotResource
    end
  end

  defmodule MultitenantOrderWithRefsResource do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshPostgresBelongsToIndex],
      validate_domain_inclusion?: false

    postgres do
      table "multitenant_orders_with_refs"
      repo TestRepo

      references do
        reference :company, on_delete: :delete
        reference :user, on_delete: :nilify
      end
    end

    multitenancy do
      strategy :attribute
      attribute :company_id
    end

    attributes do
      uuid_primary_key :id
      attribute :order_number, :string
    end

    relationships do
      belongs_to :company, CompanyResource
      belongs_to :user, UserResource
      belongs_to :depot, DepotResource
    end
  end
end
