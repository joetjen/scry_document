defmodule Scry.Document.GrammarParityTest do
  @moduledoc """
  A permanent regression guard for the equivalence between `Grammar.VM`
  (interpreted) and `Scry.Document.Grammar.Compiled` (native codegen)
  for the *merged* core+document grammar specifically -- composition,
  not just a single grammar file, is the part `impl_spec.md` itself
  flags as most likely to surface a real divergence, and this package
  fills *two* extension points at once (`select_ep1a`/`body_item_ep1`),
  not just one the way `scry_time_series` does. See `scry_core`'s own
  identical test for the single-grammar case, and `scry_time_series`'s
  own identical test for the one-extension-point case.
  """

  use ExUnit.Case, async: true

  alias Scry.Document.Grammar.Compiled

  setup_all do
    {:ok, analyzed} = Scry.Document.Grammar.compile()
    %{grammar: analyzed}
  end

  @queries [
    {"DEEP alone", "SELECT metric DEEP { value }"},
    {"DEEP + WHERE", "SELECT metric DEEP WHERE value > 10 { value }"},
    {"a plain query with no DEEP at all", "SELECT metric { value }"},
    {"PARENT alone", "SELECT nodes { title, PARENT { category } }"},
    {"nested PARENT", "SELECT nodes { title, PARENT { PARENT { category } } }"},
    {"SIBLINGS alone", "SELECT nodes { title, SIBLINGS { category } }"},
    {"ANCESTORS alone", "SELECT nodes { title, ANCESTORS { region } }"},
    {"PARENT + SIBLINGS + ANCESTORS together",
     "SELECT nodes { title, PARENT { category }, SIBLINGS { category }, ANCESTORS { region } }"},
    {"the lang_spec.md §8.3 worked example, commas added",
     ~s"""
     SELECT library.catalog.shelves.shelf.books.book
         WHERE price > 30 AND available = true LIMIT 5
     {
         title,
         PARENT { PARENT { category } },
         ANCESTORS { region }
     }
     """},
    {"block comment (via a commented-out WITH decl) before a DEEP query",
     ";with x = SELECT y { z }\nSELECT metric DEEP { value }"},
    {"the lang_spec.md §8.3 worked example verbatim, no commas at all -- " <>
       "core's newline-suffices body_list separator, through this package's own EP1(c) body items",
     ~s"""
     SELECT library.catalog.shelves.shelf.books.book
         WHERE price > 30 AND available = true LIMIT 5
     {
         title
         PARENT { PARENT { category } }
         ANCESTORS { region }
     }
     """},
    {"a trailing comma before the closing brace, mixed with a bare-newline-separated item",
     ~s"""
     SELECT nodes {
         title,
         PARENT { category }
         SIBLINGS { category },
     }
     """}
  ]

  for {label, query} <- @queries do
    test "#{label}: Grammar.VM and Scry.Document.Grammar.Compiled agree", %{grammar: grammar} do
      vm_result = Grammar.VM.run(grammar, unquote(query), Scry.Document.Actions, nil)
      compiled_result = Compiled.run(unquote(query), nil)

      assert vm_result == compiled_result
    end
  end
end
