defmodule Scry.Document.Executor do
  @moduledoc """
  Runs a parsed document query against a `Scry.Document.Conn.t()` --
  interprets `DEEP` (lang_spec.md §8.3's EP1(a) header modifier) and
  `PARENT`/`SIBLINGS`/`ANCESTORS` (its EP1(c) scoped pseudo-fields),
  neither of which `Scry.Core.Executor`/`Scry.Core.QueryOps` has any
  notion of.

  **Why this can't be a pure AST-rewrite-then-delegate pass the way
  `Scry.TimeSeries.Executor` is.** `LAST` lowers into an ordinary
  `WHERE` predicate and hands off to *any* plain engine's `execute/3`
  unmodified, because a `WHERE` predicate only ever needs the row
  already in hand. `DEEP`/`PARENT`/`SIBLINGS`/`ANCESTORS` all need
  access to the *whole* keyed document space, not just the rows behind
  one already-resolved source: `DEEP` searches across every stored key
  for a depth-agnostic match, and `PARENT`/`SIBLINGS`/`ANCESTORS` need
  to resolve *other* keys relative to whatever a row's own key is. No
  existing `Scry.Core.EngineBehaviour` callback receives the whole
  document space -- confirmed directly, not assumed (its own moduledoc
  and every real adapter's `execute/3` only ever see one already-
  resolved `conn`/`source` pair, never "the rest of the map"). So this
  module takes `Scry.Document.Conn.t()` directly rather than dispatching
  through `EngineBehaviour`.

  **Concretely:**

    * No `DEEP`: `query.source` must match a stored key exactly (the
      key convention `Scry.Document.Conn`'s own moduledoc documents).
    * `DEEP` present: resolves `query.source` (`[a, ..., z]`) against
      every stored key whose first segment is `a` and last segment is
      `z`, with any number of segments in between -- confirmed with the
      project owner as the intended reading of lang_spec.md's own
      "recursive descent, vs. one child level" phrase (XPath `//`
      semantics). A single-segment source matches every key whose own
      *last* segment equals it (there's no "first segment" to also
      require when the source itself only names one).
    * `PARENT { body }`: the row at the key with its own last segment
      dropped (`nil` if that key holds nothing, or doesn't exist) --
      singular, since a document has exactly one parent position.
    * `SIBLINGS { body }`: every row at every key sharing the same
      immediate-parent prefix, excluding the row's own key -- a list.
    * `ANCESTORS { body }`: one row per ancestor *level* (nearest
      first, root last), not just the immediate parent -- a list.
    * **Nesting one pseudo-field inside another wraps, it doesn't
      flatten** -- `PARENT { PARENT { category } }` resolves to
      `%{"parent" => %{"parent" => %{"category" => ...}}}`, not
      `%{"category" => ...}`. Each pseudo-field is an ordinary named
      body item, wrapping whatever its own body projects to under its
      own name, the same way any other body item would -- there's
      nothing pseudo-field-specific about that rule, so nothing
      special-cases it away when one is nested inside another. lang_spec.md
      §8.3's own worked example never states an expected output shape,
      so this is a deliberate, documented reading of an otherwise-open
      question, not an inferred requirement.
    * A key holding more than one row is a real, supported shape
      (`Scry.Document.Conn`'s own type allows it, matching every other
      engine's own `data()` type) -- `PARENT`/`ANCESTORS` each use only
      the *first* row at a matched key, a documented simplification for
      this round, not a silent truncation. `SIBLINGS` includes every
      row at every sibling key.
    * **Scope limit, stated rather than silently unsupported**: a
      pseudo-field alongside `GROUP BY` returns `{:error, {:unsupported,
      :pseudo_field_with_group_by}}` -- an aggregated/grouped result no
      longer corresponds to one specific document node, and neither
      lang_spec.md nor impl_spec.md says what that combination should
      mean. `%Scry.Core.CombinedQuery{}` (`UNION`/etc.) similarly
      returns `{:error, {:unsupported, :combined_query}}` this round --
      not the focal capability of this package's own first real build.
    * Ordinary `WHERE`/`ORDER BY`/`LIMIT`/`OFFSET`/plain-field
      projection are **not** reimplemented here -- delegated to `Scry.
      Core.QueryOps.run_flat/3`, the exact toolkit every other engine
      already reuses for the same purpose. A synthetic, internal-only
      per-row correlation field (never part of any real result) is
      threaded through that call solely to recover, after filtering/
      ordering/limiting, which original document key produced which
      surviving row -- `Scry.Document.Conn`'s own rows are never
      mutated; the field is added to a temporary copy and stripped
      back out before a result is ever returned.
  """

  alias Scry.Core.{Cursor, Query, QueryOps}
  alias Scry.Document.Conn

  @document_key_field "__scry_document_key__"

  @doc """
  Runs `query` against `conn`, returning a lazy `Scry.Core.Cursor.t()`
  -- the same widened contract `Scry.Core.Executor.run/3,4` and `Scry.
  TimeSeries.Executor.run/5` already have.
  """
  @spec run(Query.t() | Scry.Core.CombinedQuery.t(), Conn.t(), map()) ::
          {:ok, Cursor.t()} | {:error, term()}
  def run(query, conn, params \\ %{})

  def run(%Scry.Core.CombinedQuery{}, %Conn{}, _params) do
    {:error, {:unsupported, :combined_query}}
  end

  def run(%Query{} = query, %Conn{data: document}, params) do
    with {:ok, matches} <- resolve_source(document, query.source, deep?(query)) do
      if extract_pseudo_items(query.select) == [] do
        # No PARENT/SIBLINGS/ANCESTORS anywhere in this query's own
        # top-level select -- nothing document-specific to do.
        # Delegating wholesale, unmodified query included, is the
        # correctness-critical path here: GROUP BY/aggregation only
        # works correctly when `run_flat/3` sees every row belonging
        # to a group *at once* -- the marker-per-row technique `order_
        # and_limit/3`/`project_all/3` need is only ever safe for a
        # non-grouped, row-for-row correspondence (confirmed by a
        # real, caught-by-test regression: an ordinary `GROUP BY` with
        # no pseudo items at all silently miscounted under the marker
        # path, since it necessarily processes one row at a time and
        # never lets `run_flat/3` see the whole group).
        rows = Enum.map(matches, fn {_key, row} -> row end)

        with {:ok, enumerable} <- QueryOps.run_flat(rows, query, params) do
          {:ok, Cursor.new(enumerable)}
        end
      else
        with :ok <- validate_no_grouping(query),
             {:ok, ordered} <- order_and_limit(matches, query, params) do
          case project_all(ordered, query.select, document) do
            {:ok, rows} -> {:ok, Cursor.new(rows)}
            {:error, _reason} = error -> error
          end
        end
      end
    end
  end

  defp deep?(%Query{variant: %{select_ep1a: :deep}}), do: true
  defp deep?(_query), do: false

  defp validate_no_grouping(%Query{group_bys: []}), do: :ok
  defp validate_no_grouping(_query), do: {:error, {:unsupported, :pseudo_field_with_group_by}}

  defp resolve_source(document, source, false) do
    case Map.fetch(document, source) do
      {:ok, rows} -> {:ok, Enum.map(rows, &{source, &1})}
      :error -> {:error, {:query_error, {:no_such_source, source}}}
    end
  end

  defp resolve_source(document, source, true) do
    matches =
      document
      |> Enum.filter(fn {key, _rows} -> deep_match?(key, source) end)
      |> Enum.sort_by(fn {key, _rows} -> key end)
      |> Enum.flat_map(fn {key, rows} -> Enum.map(rows, &{key, &1}) end)

    {:ok, matches}
  end

  defp deep_match?(key, [only]), do: List.last(key) == only

  defp deep_match?(key, source) do
    List.first(key) == List.first(source) and List.last(key) == List.last(source)
  end

  # Threads a unique, synthetic per-row index through `run_flat/3`
  # (not the document key itself -- two distinct matched rows can
  # legitimately share the same key) so the post-filter/order/limit
  # survivor list can be mapped back to its own original `{key, row}`
  # pair. `run_flat/3` only ever needs *a* select to run; the marker
  # field is the only one it's given here, since projecting the real
  # select happens afterward, in `project_all/3`, against the
  # untouched original rows.
  defp order_and_limit(matches, query, params) do
    indexed = Enum.with_index(matches)
    lookup = Map.new(indexed, fn {{key, row}, idx} -> {idx, {key, row}} end)

    tagged_rows =
      Enum.map(indexed, fn {{_key, row}, idx} -> Map.put(row, @document_key_field, idx) end)

    marker_query = %{query | select: [{:field, [@document_key_field]}]}

    with {:ok, marker_rows} <- QueryOps.run_flat(tagged_rows, marker_query, params) do
      ordered =
        Enum.map(marker_rows, fn %{@document_key_field => idx} -> Map.fetch!(lookup, idx) end)

      {:ok, ordered}
    end
  end

  defp project_all(ordered, select, document) do
    ordered
    |> Enum.map(fn {key, row} -> project_body(key, row, select, document) end)
    |> Enum.split_with(&match?({:error, _}, &1))
    |> case do
      {[], oks} -> {:ok, Enum.map(oks, fn {:ok, row} -> row end)}
      {[first_error | _], _rows} -> first_error
    end
  end

  # Projects one already-resolved `{key, row}` against `body` -- plain
  # fields/nested SELECTs/etc. delegate to `Scry.Core.QueryOps.run_flat/3`
  # exactly as `project_all/3`'s own caller does (no WHERE/ORDER/LIMIT
  # here -- a pseudo-field's own `{ <body> }` has no clause syntax of
  # its own, lang_spec.md §8.3's own grammar column confirms this),
  # `PARENT`/`SIBLINGS`/`ANCESTORS` resolve recursively through this
  # same function, one level relative to `key`.
  defp project_body(key, row, body, document) do
    pseudo_items = extract_pseudo_items(body)
    ordinary_select = strip_pseudo_items(body)

    with {:ok, base} <- project_ordinary(row, ordinary_select) do
      resolved =
        Enum.reduce(pseudo_items, base, fn {output_key, kind, nested_body}, acc ->
          Map.put(acc, output_key, resolve_pseudo_field(kind, nested_body, key, document))
        end)

      {:ok, resolved}
    end
  end

  defp project_ordinary(_row, []), do: {:ok, %{}}

  defp project_ordinary(row, select) do
    flat_query = %Query{
      source: nil,
      wheres: [],
      group_bys: [],
      group_mode: :plain,
      havings: [],
      distinct: false,
      order_bys: [],
      limit: nil,
      offset: nil,
      required: false,
      select: select,
      variant: %{},
      with_bindings: %{},
      type_decls: %{}
    }

    case QueryOps.run_flat([row], flat_query, %{}) do
      {:ok, enumerable} ->
        case Enum.to_list(enumerable) do
          [projected] -> {:ok, projected}
          [] -> {:ok, %{}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp extract_pseudo_items(body_items) do
    Enum.flat_map(body_items, fn
      {:variant, {kind, body}} when kind in [:parent, :siblings, :ancestors] ->
        [{Atom.to_string(kind), kind, body}]

      _other ->
        []
    end)
  end

  defp strip_pseudo_items(body_items) do
    Enum.reject(body_items, fn
      {:variant, {kind, _body}} when kind in [:parent, :siblings, :ancestors] -> true
      _other -> false
    end)
  end

  defp resolve_pseudo_field(:parent, body, key, document) do
    case parent_key(key) do
      nil -> nil
      parent_key -> project_first(parent_key, body, document)
    end
  end

  defp resolve_pseudo_field(:siblings, body, key, document) do
    parent = parent_key(key)

    document
    |> Enum.filter(fn {k, _rows} -> k != key and parent_key(k) == parent end)
    |> Enum.sort_by(fn {k, _rows} -> k end)
    |> Enum.flat_map(fn {sibling_key, rows} ->
      Enum.map(rows, fn row ->
        {:ok, projected} = project_body(sibling_key, row, body, document)
        projected
      end)
    end)
  end

  defp resolve_pseudo_field(:ancestors, body, key, document) do
    key
    |> ancestor_keys()
    |> Enum.map(&project_first(&1, body, document))
  end

  defp project_first(key, body, document) do
    case Map.fetch(document, key) do
      {:ok, [row | _rest]} ->
        {:ok, projected} = project_body(key, row, body, document)
        projected

      _absent ->
        nil
    end
  end

  defp parent_key([_single]), do: nil
  defp parent_key(key), do: Enum.drop(key, -1)

  defp ancestor_keys(key) when length(key) <= 1, do: []
  defp ancestor_keys(key), do: for(i <- (length(key) - 1)..1//-1, do: Enum.take(key, i))
end
