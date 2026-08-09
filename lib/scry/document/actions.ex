defmodule Scry.Document.Actions do
  @moduledoc """
  Turns the *merged* (core + this package's own fragment) parse tree
  into a `%Scry.Core.Query{}`, the exact same target `Scry.Core.Actions`
  produces alone -- this module owns exactly the rules `priv/grammar.
  aether` adds (`select_ep1a` for lang_spec.md §8.3's `DEEP`, and
  `body_item_ep1`/`parent_field`/`siblings_field`/`ancestors_field` for
  `PARENT`/`SIBLINGS`/`ANCESTORS`) and delegates every other rule/token
  straight through to `Scry.Core.Actions`'s own functions, the same
  delegation-not-composition shape `scry_time_series`'s own identical
  module already established (see that module's own moduledoc for the
  full "why delegation, not a generic composed-Actions mechanism, and
  why naive delegation is subtly wrong" reasoning -- identical here,
  not re-derived).

  `body_item`'s own handler, in `Scry.Core.Actions`, already wraps
  whatever this module's `body_item_ep1` handler returns as `{:variant,
  value}` -- confirmed by reading it directly (`handle_rule(:body_item,
  %{body_item_ep1: cap}, ctx)`), so `parent_field`/`siblings_field`/
  `ancestors_field`'s own handlers below only need to produce their own
  tagged tuple (`{:parent, body}`, etc.); core wraps it one level
  further automatically. A resolved query's own `select` list therefore
  contains `{:variant, {:parent, body_items}}` (and so on) alongside
  whatever other body-item shapes core already produces (`{:field,
  path}`, a nested `%Scry.Core.Query{}`, ...) -- `Scry.Document.
  Executor` is what actually interprets these tagged tuples; `Scry.
  Core.Executor`/`Scry.Core.QueryOps` have no notion of them at all.
  """

  @behaviour Ichor.Actions

  alias Ichor.Capture

  @impl true
  def handle_token(name, text, ctx) do
    Scry.Core.Actions.handle_token(name, text, ctx)
  rescue
    e in FunctionClauseError ->
      if delegate_had_no_clause?(e, :handle_token) do
        {:ok, text, ctx}
      else
        reraise e, __STACKTRACE__
      end
  end

  # lang_spec.md §8.3: bare `DEEP`, EP1(a) header modifier, nominated
  # position "before where" -- the same position `LAST` (time-series)
  # nominates, mutually exclusive by kind, never both on one query.
  # Unlike `LAST`, `DEEP` takes no arguments at all (`select_ep1a :=
  # KW_DEEP`, no named captures), so its handler tags the result the
  # bare atom `:deep`, not a payload tuple -- `query.variant.select_ep1a`
  # is exactly `:deep` when present. Neither `Scry.Core.Query` nor
  # `Scry.Core.Executor` knows what that means -- `Scry.Document.
  # Executor` (not `Scry.Core.Executor`) is what actually interprets it.
  @impl true
  def handle_rule(:select_ep1a, _captures, ctx), do: {:ok, :deep, ctx}

  # `body_item_ep1 := parent_field | siblings_field | ancestors_field`
  # -- a bare single-capture alternation, same shape `last_bound`'s own
  # dispatch (in scry_time_series) already establishes: whichever
  # alternative matched is the sole key in `captures`, so each clause
  # below just evaluates it straight through.
  def handle_rule(:body_item_ep1, %{parent_field: cap}, ctx), do: cap.eval.(ctx)
  def handle_rule(:body_item_ep1, %{siblings_field: cap}, ctx), do: cap.eval.(ctx)
  def handle_rule(:body_item_ep1, %{ancestors_field: cap}, ctx), do: cap.eval.(ctx)

  # `PARENT { <body> }`/`SIBLINGS { <body> }`/`ANCESTORS { <body> }` --
  # lang_spec.md §8.3's EP1(c) scoped pseudo-fields, the XPath
  # `parent::`/sibling-axis/`ancestor::` equivalents. `inner:body_list`
  # evaluates through core's own real `body_list`/`body_item` handlers
  # (this package contributes no body-item evaluation logic of its own
  # beyond these three tags) into an ordinary Elixir list, the exact
  # same shape a nested SELECT's own `select` list already has.
  def handle_rule(:parent_field, %{inner: inner_cap}, ctx) do
    with {:ok, body, ctx} <- inner_cap.eval.(ctx), do: {:ok, {:parent, body}, ctx}
  end

  def handle_rule(:siblings_field, %{inner: inner_cap}, ctx) do
    with {:ok, body, ctx} <- inner_cap.eval.(ctx), do: {:ok, {:siblings, body}, ctx}
  end

  def handle_rule(:ancestors_field, %{inner: inner_cap}, ctx) do
    with {:ok, body, ctx} <- inner_cap.eval.(ctx), do: {:ok, {:ancestors, body}, ctx}
  end

  def handle_rule(rule, captures, ctx) do
    Scry.Core.Actions.handle_rule(rule, captures, ctx)
  rescue
    e in FunctionClauseError ->
      if delegate_had_no_clause?(e, :handle_rule) do
        default_handle_rule(rule, captures, ctx)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp delegate_had_no_clause?(%FunctionClauseError{} = e, expected_function) do
    e.module == Scry.Core.Actions and e.function == expected_function and e.arity == 3
  end

  # `default_handle_rule/3`/`build_node/3`: a direct port of
  # `Ichor.Actions`'s own identically-named private functions
  # (`ichor_runtime`, `lib/ichor/actions.ex`) -- see this module's own
  # moduledoc, and `scry_time_series`'s own identical functions, for why
  # a port, not a call, is necessary here.
  defp default_handle_rule(rule_name, captures, ctx) when map_size(captures) == 1 do
    case Map.to_list(captures) do
      [{_name, %Capture{} = cap}] -> cap.eval.(ctx)
      [{_name, list}] when is_list(list) -> build_node(rule_name, captures, ctx)
    end
  end

  defp default_handle_rule(rule_name, captures, ctx), do: build_node(rule_name, captures, ctx)

  defp build_node(rule_name, captures, ctx) do
    with {:ok, resolved, ctx} <- Ichor.Actions.eval_all(captures, ctx) do
      {:ok, %Ichor.Node{rule: rule_name, captures: resolved, span: nil}, ctx}
    end
  end
end
