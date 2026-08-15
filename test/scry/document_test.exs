defmodule Scry.DocumentTest do
  use ExUnit.Case, async: true

  alias Scry.Core.{CombinedQuery, Query}

  test "DEEP, the §8.3 EP1(a) header modifier -- a bare keyword, no arguments" do
    assert {:ok, %Query{} = q} = Scry.Document.parse("SELECT metric DEEP { value }")
    assert q.variant == %{select_ep1a: :deep}
  end

  test "DEEP is case-insensitive, matching every other structural keyword" do
    assert {:ok, %Query{} = q} = Scry.Document.parse("SELECT metric deep { value }")
    assert q.variant == %{select_ep1a: :deep}
  end

  test "a plain query with no DEEP at all parses exactly as Scry.Core.parse/1 already would" do
    assert {:ok, %Query{} = q} = Scry.Document.parse("SELECT metric { value }")
    assert q.variant == %{}
    assert q.source == ["metric"]
    assert q.select == [{:field, ["value"]}]
  end

  test "DEEP combined with a real WHERE clause -- the merged grammar still runs core's own logic" do
    assert {:ok, %Query{} = q} =
             Scry.Document.parse("SELECT metric DEEP WHERE value > 10 { value }")

    assert q.variant == %{select_ep1a: :deep}
    assert q.wheres == [{:cmp, :gt, ["value"], 10}]
  end

  test "DEEP used after WHERE (not its own nominated position) is a parse error" do
    assert {:error, _} = Scry.Document.parse("SELECT metric WHERE value > 1 DEEP { value }")
  end

  describe "PARENT/SIBLINGS/ANCESTORS -- §8.3's EP1(c) scoped pseudo-fields" do
    test "PARENT wraps as {:variant, {:parent, body}} inside select, via core's own body_item wrapping" do
      assert {:ok, %Query{} = q} =
               Scry.Document.parse("SELECT nodes { title, PARENT { category } }")

      assert q.select == [
               {:field, ["title"]},
               {:variant, {:parent, [{:field, ["category"]}]}}
             ]
    end

    test "SIBLINGS, same shape" do
      assert {:ok, %Query{} = q} =
               Scry.Document.parse("SELECT nodes { title, SIBLINGS { category } }")

      assert q.select == [
               {:field, ["title"]},
               {:variant, {:siblings, [{:field, ["category"]}]}}
             ]
    end

    test "ANCESTORS, same shape" do
      assert {:ok, %Query{} = q} =
               Scry.Document.parse("SELECT nodes { title, ANCESTORS { region } }")

      assert q.select == [
               {:field, ["title"]},
               {:variant, {:ancestors, [{:field, ["region"]}]}}
             ]
    end

    test "nesting: PARENT { PARENT { ... } } -- its own body recurses back into core's real body_list" do
      assert {:ok, %Query{} = q} =
               Scry.Document.parse("SELECT nodes { PARENT { PARENT { category } } }")

      assert q.select == [
               {:variant, {:parent, [{:variant, {:parent, [{:field, ["category"]}]}}]}}
             ]
    end

    test "all three together, plus a nested field inside each, and case-insensitivity" do
      assert {:ok, %Query{} = q} =
               Scry.Document.parse(
                 "SELECT nodes { title, parent { a }, siblings { b }, ancestors { c } }"
               )

      assert q.select == [
               {:field, ["title"]},
               {:variant, {:parent, [{:field, ["a"]}]}},
               {:variant, {:siblings, [{:field, ["b"]}]}},
               {:variant, {:ancestors, [{:field, ["c"]}]}}
             ]
    end

    test "a PARENT body item composes alongside an ordinary nested SELECT in the same body" do
      assert {:ok, %Query{} = q} =
               Scry.Document.parse(
                 "SELECT nodes { title, PARENT { category }, SELECT other { x } }"
               )

      assert [{:field, ["title"]}, {:variant, {:parent, _}}, %Query{source: ["other"]}] = q.select
    end

    # Commas added between body items -- no longer required since core's
    # body_list gained a newline-suffices separator (scry_core
    # §6); kept here as a still-valid, comma-explicit rendering of the
    # worked example. See grammar_parity_test.exs for a verbatim,
    # no-commas-at-all case exercising the newline-only form.
    test "the §8.3 worked example, with explicit commas between body items" do
      assert {:ok, %Query{} = q} =
               Scry.Document.parse(~s"""
               SELECT library.catalog.shelves.shelf.books.book
                   WHERE price > 30 AND available = true LIMIT 5
               {
                   title,
                   PARENT { PARENT { category } },
                   ANCESTORS { region }
               }
               """)

      assert q.source == ["library", "catalog", "shelves", "shelf", "books", "book"]
      assert q.limit == 5

      assert q.select == [
               {:field, ["title"]},
               {:variant, {:parent, [{:variant, {:parent, [{:field, ["category"]}]}}]}},
               {:variant, {:ancestors, [{:field, ["region"]}]}}
             ]
    end
  end

  test "a document-level construct (WITH) untouched by either extension point, through the delegated Actions module" do
    assert {:ok, %Query{} = q} =
             Scry.Document.parse(
               "WITH recent = SELECT metric DEEP { value } SELECT recent { value }"
             )

    assert Map.has_key?(q.with_bindings, "recent")
    assert q.with_bindings["recent"].variant == %{select_ep1a: :deep}
  end

  test "a combinator (UNION) also composes correctly, returning a real %CombinedQuery{}" do
    assert {:ok, %CombinedQuery{} = q} =
             Scry.Document.parse(
               "SELECT metric DEEP { value } UNION SELECT other_metric { value }"
             )

    assert q.op == :union
    assert q.left.variant == %{select_ep1a: :deep}
  end

  test "TYPE/FRAGMENT declarations, built entirely by core, still work through delegation" do
    assert {:ok, %Query{} = q} =
             Scry.Document.parse(
               "TYPE Metric { value: Int } FRAGMENT v { value } SELECT metric DEEP { ...v }"
             )

    assert Map.has_key?(q.type_decls, "Metric")
    assert q.select == [{:field, ["value"]}]
    assert q.variant == %{select_ep1a: :deep}
  end

  describe "Scry.Core.TypeCheck's category check (§7)" do
    test "a source declared TYPE ...: relational using DEEP is a compile-time error, same as LAST" do
      assert {:error, {:kind_category_mismatch, "metric", "relational", [:select_ep1a]}} =
               Scry.Document.parse(
                 "TYPE metric: relational { value: Int } SELECT metric DEEP { value }"
               )
    end

    test "the same source declared TYPE ...: olap using DEEP is also a compile-time error" do
      assert {:error, {:kind_category_mismatch, "metric", "olap", [:select_ep1a]}} =
               Scry.Document.parse(
                 "TYPE metric: olap { value: Int } SELECT metric DEEP { value }"
               )
    end

    # scry_core's own category check now also catches this: its
    # cross-kind check walks query.select's {:variant, {tag, body}}
    # tagged body items too (not just query.variant, the EP1(a) header
    # modifier slot DEEP alone uses), via a hardcoded tag-to-kind
    # registry that includes :parent/:siblings/:ancestors as
    # "document"-kind tags. Confirmed directly against Scry.Core.
    # TypeCheck's own source, not assumed -- this closes what was
    # previously a known, documented scope gap in that check.
    test "PARENT on a TYPE ...: relational source is caught by the cross-kind category check" do
      assert {:error, {:kind_category_mismatch, "nodes", "relational", [:parent]}} =
               Scry.Document.parse(
                 "TYPE nodes: relational { title: String } SELECT nodes { title, PARENT { category } }"
               )
    end

    test "an unmatched TYPE name (relational, but not this source) is inert, DEEP still parses" do
      assert {:ok, %Query{} = q} =
               Scry.Document.parse(
                 "TYPE Other: relational { value: Int } SELECT metric DEEP { value }"
               )

      assert q.variant == %{select_ep1a: :deep}
    end
  end
end
