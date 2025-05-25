defmodule AshPostgresBelongsToIndex.Info do
  use Spark.InfoGenerator,
    extension: AshPostgresBelongsToIndex,
    sections: [:postgres_belongs_to_index]
end
