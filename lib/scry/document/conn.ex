defmodule Scry.Document.Conn do
  @moduledoc """
  The document tree `Scry.Document.Executor.run/3` reads from -- a
  reference structure, not a real backing adapter (`impl_spec.md` §6
  lists no document-store product as a day-one build target yet; this
  package's own README/CHANGELOG have the full "why no `scry_engine_*`
  package this round" reasoning).

  Reuses the exact `%{[String.t(), ...] => [row]}` shape every other
  `Scry.Core.EngineBehaviour`-adjacent connection already has (`Scry.
  Engine.InMemory.Conn`, e.g.) -- no new storage primitive. The only
  difference: a key's own segments are now meaningful as tree position,
  not just a longer flat identifier -- `["library", "catalog", "shelf"]`
  is the parent of `["library", "catalog", "shelf", "book"]`, the same
  convention a filesystem path uses. `Scry.Document.Executor`'s own
  moduledoc has the full reasoning for why this data convention is
  enough to support `DEEP`/`PARENT`/`SIBLINGS`/`ANCESTORS` with no new
  storage type.
  """

  @typedoc "Keyed by a document's own tree position -- segment order encodes nesting."
  @type data :: %{optional([String.t(), ...]) => [Scry.Core.EngineBehaviour.row()]}

  @type t :: %__MODULE__{data: data()}

  defstruct data: %{}

  @doc "Builds a `Conn` from a plain `%{path => rows}` map -- empty by default."
  @spec new(data()) :: t()
  def new(data \\ %{}) when is_map(data), do: %__MODULE__{data: data}
end
