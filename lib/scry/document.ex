defmodule Scry.Document do
  @moduledoc """
  The `document` kind for [Scry](https://github.com/joetjen/scry)
  (lang_spec.md §8.3) -- `DEEP` (an EP1(a) header modifier, recursive
  descent through a hierarchical source) and `PARENT`/`SIBLINGS`/
  `ANCESTORS` (EP1(c) scoped pseudo-fields, the XPath `parent::`/
  sibling-axis/`ancestor::` equivalents) only. This package's own
  README/CHANGELOG have the full scope reasoning.

  `parse/1` mirrors `Scry.Core.parse/1`'s own shape and is the intended
  entry point for anything outside this package that only needs to
  parse. `Scry.Document.Executor.run/4` is the intended entry point for
  anything that also needs to *execute* a parsed query -- neither
  `DEEP` nor `PARENT`/`SIBLINGS`/`ANCESTORS` mean anything to `Scry.
  Core.Executor` on its own, and unlike `scry_time_series`'s own
  `LAST`, these constructs need access to the *whole* document space
  (not just one already-resolved source's own rows) to mean anything at
  all -- see `Scry.Document.Executor`'s own moduledoc for the full "why
  a document executor can't be a pure AST-rewrite-then-delegate pass
  the way `Scry.TimeSeries.Executor` is" reasoning.
  """

  alias Scry.Core.{CombinedQuery, Query}

  @doc """
  Parses `source` (Scry query text) into a `%Scry.Core.Query{}` (or a
  `%Scry.Core.CombinedQuery{}`, per `Scry.Core.parse/1`'s own combinator
  handling), using `Scry.Document.Grammar.Compiled` -- checked-in,
  pre-generated from core merged with this package's own fragment (see
  `Scry.Document.Grammar`'s own moduledoc). A query using `DEEP`
  resolves it into `query.variant.select_ep1a` (the bare atom `:deep`);
  a `PARENT { ... }`/`SIBLINGS { ... }`/`ANCESTORS { ... }` body item
  resolves into `{:variant, {:parent, body}}`/`{:variant, {:siblings,
  body}}`/`{:variant, {:ancestors, body}}` inside `query.select` (core's
  own `body_item` handler wraps every `body_item_ep1` contribution in
  `{:variant, ...}` automatically). A query with none of these behaves
  exactly as `Scry.Core.parse/1` already does, since every one of
  core's own rules is unchanged by this package's own composition.
  Neither construct is executed by `parse/1` itself -- see `Scry.
  Document.Executor.run/4` for that.
  """
  @spec parse(String.t()) :: {:ok, Query.t() | CombinedQuery.t()} | {:error, term()}
  def parse(source) when is_binary(source) do
    Scry.Document.Grammar.Compiled.run(source, nil)
  end
end
