defmodule AshPostgresBelongsToIndex do
  @postgres_belongs_to_index %Spark.Dsl.Section{
    name: :postgres_belongs_to_index,
    describe: """
    Automatically adds AshPostgres custom indexes for `belongs_to` relationships in Ash resources.
    """,
    examples: [
      """
      postgres_belongs_to_index do
        except [:belongs_to_relationship_to_exclude]
      end
      """
    ],
    schema: [
      except: [
        type: {:wrap_list, :atom},
        required: false,
        default: [],
        doc: "A list of `belongs_to` relationships to exclude from automatic indexing."
      ]
    ],
    entities: []
  }

  use Spark.Dsl.Extension,
    sections: [@postgres_belongs_to_index],
    transformers: [AshPostgresBelongsToIndex.Transformer]
end
