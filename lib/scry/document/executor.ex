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
      pseudo-field *or a nested `SELECT`* alongside `GROUP BY` returns
      `{:error, {:unsupported, :pseudo_field_with_group_by}}` (the atom
      name predates nested `SELECT` support and is kept as-is rather
      than churned) -- an aggregated/grouped result no longer
      corresponds to one specific document node, and neither
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
    * A nested `%Scry.Core.Query{}` body item -- Scry's own `JOIN`
      equivalent -- is the one shape `run_flat/3` genuinely cannot
      resolve at all (confirmed via a real `FunctionClauseError`, not
      assumed; `Scry.Core.QueryOps.resolve_correlated_nested/5`'s own
      moduledoc has the full story), found building `scry_reldoc`:
      *any* query combining a nested `SELECT` with anything document-
      specific -- or even with nothing document-specific at all, since
      the old "no pseudo items" fast path handed the query to
      `run_flat/3` completely unmodified -- crashed outright. Fixed via
      `resolve_correlated_nested/5`, called with a `fetch_fn` that
      recurses back into this module's own `run/3` (so a nested
      `SELECT` may itself contain another nested `SELECT`, or this
      package's own pseudo-fields, fully recursively). Correlation
      always resolves against the *original, top-level* query's own
      source name, even when this recurses into a `PARENT`/`SIBLINGS`/
      `ANCESTORS` body -- correlating to anything else from inside a
      pseudo-field's own nested body is a real, stated scope limit
      (lang_spec.md/impl_spec.md define no correlation semantics for
      that position at all), not silently wrong.
    * **`own_name` (the correlation anchor) is always `List.last(query.
      source)`, one segment only** -- a genuine, pre-existing `scry_core`
      limit (`Scry.Core.QueryOps.run_document/4`'s own moduledoc: "not
      a two-or-more-segment path under the ancestor"), confirmed the
      hard way here: a document source is very often multi-segment
      (`catalog.fiction`), but correlating a nested `SELECT` against it
      must still write only the *last* segment (`WHERE book_id =
      fiction.id`, not `WHERE book_id = catalog.fiction.id`) -- the
      full multi-segment form silently fails to correlate at all
      (resolves as an ordinary, missing field instead, surfacing as a
      null-safety error rather than a clear "didn't correlate" one).
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

  def run(%Query{} = query, %Conn{data: document} = conn, params) do
    with {:ok, matches} <- resolve_source(document, query.source, deep?(query)) do
      if special_items?(query.select) do
        with :ok <- validate_no_grouping(query),
             {:ok, ordered} <- order_and_limit(matches, query, params) do
          own_name = List.last(query.source)

          case project_all(ordered, query.select, conn, own_name, params) do
            {:ok, rows} -> {:ok, Cursor.new(rows)}
            {:error, _reason} = error -> error
          end
        end
      else
        # Neither a PARENT/SIBLINGS/ANCESTORS pseudo-field nor a nested
        # SELECT anywhere in this query's own top-level select --
        # nothing document-specific to do. Delegating wholesale,
        # unmodified query included, is the correctness-critical path
        # here: GROUP BY/aggregation only works correctly when `run_flat/3`
        # sees every row belonging to a group *at once* -- the
        # marker-per-row technique `order_and_limit/3`/`project_all/3`
        # need is only ever safe for a non-grouped, row-for-row
        # correspondence (confirmed by a real, caught-by-test
        # regression: an ordinary `GROUP BY` with no special items at
        # all silently miscounted under the marker path, since it
        # necessarily processes one row at a time and never lets
        # `run_flat/3` see the whole group).
        rows = Enum.map(matches, fn {_key, row} -> row end)

        with {:ok, enumerable} <- QueryOps.run_flat(rows, query, params) do
          {:ok, Cursor.new(enumerable)}
        end
      end
    end
  end

  # A bare nested `%Scry.Core.Query{}` body item needs the identical
  # per-row marker path a pseudo-field does -- `run_flat/3` cannot
  # resolve one at all (`Scry.Core.QueryOps.resolve_correlated_nested/5`'s
  # own moduledoc has the full "confirmed via a real FunctionClauseError"
  # story; found empirically that this bit even a query with *no*
  # pseudo-field at all, since the old fast path called `run_flat/3`
  # with the query completely unmodified, nested SELECT included).
  defp special_items?(body_items) do
    Enum.any?(body_items, fn
      {:variant, {kind, _body}} when kind in [:parent, :siblings, :ancestors] -> true
      %Query{} -> true
      _other -> false
    end)
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

  defp project_all(ordered, select, conn, own_name, params) do
    ordered
    |> Enum.map(fn {key, row} -> project_body(key, row, select, conn, own_name, params) end)
    |> Enum.split_with(&match?({:error, _}, &1))
    |> case do
      {[], oks} -> {:ok, Enum.map(oks, fn {:ok, row} -> row end)}
      {[first_error | _], _rows} -> first_error
    end
  end

  # Projects one already-resolved `{key, row}` against `body` -- plain
  # fields delegate to `Scry.Core.QueryOps.run_flat/3` (no WHERE/ORDER/
  # LIMIT here -- a pseudo-field's own `{ <body> }` has no clause syntax
  # of its own, lang_spec.md §8.3's own grammar column confirms this),
  # a nested `%Scry.Core.Query{}` body item resolves via `Scry.Core.
  # QueryOps.resolve_correlated_nested/5` (that function's own moduledoc
  # has the full "why `run_flat/3` alone can't do this" story), and
  # `PARENT`/`SIBLINGS`/`ANCESTORS` resolve recursively through this
  # same function, one level relative to `key`. `own_name` is always
  # the *original, top-level* query's own source name, unchanged as
  # this recurses into a pseudo-field's own nested body -- correlation
  # inside a `PARENT`/`SIBLINGS`/`ANCESTORS` body referencing something
  # other than the true top-level source is a real, stated scope limit,
  # not silently wrong: lang_spec.md/impl_spec.md define no correlation
  # semantics for that position at all, and `run_document/4`'s own
  # identical "immediate enclosing query only" limit is the closest
  # existing precedent.
  defp project_body(key, row, body, conn, own_name, params) do
    pseudo_items = extract_pseudo_items(body)

    {nested_items, flat_select} =
      body |> strip_pseudo_items() |> Enum.split_with(&is_struct(&1, Query))

    with {:ok, base} <- project_ordinary(row, flat_select, params),
         {:ok, with_nested} <- add_nested_results(base, nested_items, row, conn, own_name, params) do
      resolved =
        Enum.reduce(pseudo_items, with_nested, fn {output_key, kind, nested_body}, acc ->
          Map.put(
            acc,
            output_key,
            resolve_pseudo_field(kind, nested_body, key, conn, own_name, params)
          )
        end)

      {:ok, resolved}
    end
  end

  defp add_nested_results(base, [], _row, _conn, _own_name, _params), do: {:ok, base}

  defp add_nested_results(base, nested_items, row, conn, own_name, params) do
    Enum.reduce_while(nested_items, {:ok, base}, fn nested, {:ok, acc} ->
      fetch_fn = fn q, p ->
        with {:ok, cursor} <- run(q, conn, p) do
          {:ok, Cursor.to_list(cursor)}
        end
      end

      case QueryOps.resolve_correlated_nested(nested, row, own_name, params, fetch_fn) do
        {:ok, rows} -> {:cont, {:ok, Map.put(acc, List.last(nested.source), rows)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp project_ordinary(_row, [], _params), do: {:ok, %{}}

  # The `QueryOps.run_flat/3` call just below is `.dialyzer_ignore.exs`'s
  # own `:call` entry -- a confirmed dialyzer false positive (verified
  # this exact struct literal round-trips correctly at runtime), see
  # that file's own comment for the full explanation.
  defp project_ordinary(row, select, params) do
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

    case QueryOps.run_flat([row], flat_query, params) do
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

  defp resolve_pseudo_field(:parent, body, key, conn, own_name, params) do
    case parent_key(key) do
      nil -> nil
      parent_key -> project_first(parent_key, body, conn, own_name, params)
    end
  end

  defp resolve_pseudo_field(:siblings, body, key, conn, own_name, params) do
    parent = parent_key(key)

    conn.data
    |> Enum.filter(fn {k, _rows} -> k != key and parent_key(k) == parent end)
    |> Enum.sort_by(fn {k, _rows} -> k end)
    |> Enum.flat_map(fn {sibling_key, rows} ->
      Enum.map(rows, fn row ->
        {:ok, projected} = project_body(sibling_key, row, body, conn, own_name, params)
        projected
      end)
    end)
  end

  defp resolve_pseudo_field(:ancestors, body, key, conn, own_name, params) do
    key
    |> ancestor_keys()
    |> Enum.map(&project_first(&1, body, conn, own_name, params))
  end

  defp project_first(key, body, conn, own_name, params) do
    case Map.fetch(conn.data, key) do
      {:ok, [row | _rest]} ->
        {:ok, projected} = project_body(key, row, body, conn, own_name, params)
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
