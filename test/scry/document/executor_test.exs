defmodule Scry.Document.ExecutorTest do
  @moduledoc """
  Real execution coverage for `DEEP`/`PARENT`/`SIBLINGS`/`ANCESTORS` --
  `Scry.Document.parse/1` alone only proves these constructs parse
  into the right AST; this file proves `Scry.Document.Executor.run/3`
  actually interprets them correctly against a real (if hand-built)
  document tree, including the `lang_spec.md` §8.3 worked example run
  for real, not just traced by hand.
  """

  use ExUnit.Case, async: true

  alias Scry.Core.Cursor
  alias Scry.Document.Conn
  alias Scry.Document.Executor

  defp run!(conn, source) do
    {:ok, query} = Scry.Document.parse(source)
    {:ok, cursor} = Executor.run(query, conn)
    Cursor.to_list(cursor)
  end

  describe "no DEEP -- exact key match, today's ordinary behavior" do
    test "matches only the literal key" do
      conn = Conn.new(%{["users"] => [%{"name" => "Alice"}]})
      assert run!(conn, "SELECT users { name }") == [%{"name" => "Alice"}]
    end

    test "an unknown exact source is a clear error, not a crash" do
      conn = Conn.new(%{["users"] => [%{"name" => "Alice"}]})
      {:ok, query} = Scry.Document.parse("SELECT nonexistent { name }")

      assert {:error, {:query_error, {:no_such_source, ["nonexistent"]}}} =
               Executor.run(query, conn)
    end

    test "ordinary WHERE/ORDER BY/LIMIT still work, delegated to Scry.Core.QueryOps" do
      conn =
        Conn.new(%{
          ["users"] => [
            %{"name" => "Alice", "age" => 30},
            %{"name" => "Bob", "age" => 17},
            %{"name" => "Carol", "age" => 40}
          ]
        })

      assert run!(conn, "SELECT users WHERE age > 18 ORDER BY age DESC LIMIT 1 { name }") ==
               [%{"name" => "Carol"}]
    end
  end

  describe "DEEP -- XPath // semantics, matches at any depth" do
    setup do
      conn =
        Conn.new(%{
          ["library", "shelf", "book"] => [%{"title" => "Deeply Nested"}],
          ["library", "book"] => [%{"title" => "Direct Child"}],
          ["other", "book"] => [%{"title" => "Wrong Root"}]
        })

      %{conn: conn}
    end

    test "matches both a direct child and a deeply-nested descendant sharing the first/last segment",
         %{conn: conn} do
      titles = conn |> run!("SELECT library.book DEEP { title }") |> Enum.map(& &1["title"])
      assert Enum.sort(titles) == ["Deeply Nested", "Direct Child"]
    end

    test "never matches a key with a different first segment", %{conn: conn} do
      titles = conn |> run!("SELECT library.book DEEP { title }") |> Enum.map(& &1["title"])
      refute "Wrong Root" in titles
    end

    test "a single-segment source only constrains the last segment (no first-segment check possible)" do
      conn =
        Conn.new(%{
          ["a", "b", "book"] => [%{"title" => "Nested"}],
          ["book"] => [%{"title" => "Top-level"}]
        })

      titles = conn |> run!("SELECT book DEEP { title }") |> Enum.map(& &1["title"])
      assert Enum.sort(titles) == ["Nested", "Top-level"]
    end

    test "without DEEP, the same multi-segment source only matches the literal key" do
      conn =
        Conn.new(%{
          ["library", "shelf", "book"] => [%{"title" => "Deeply Nested"}],
          ["library", "book"] => [%{"title" => "Direct Child"}]
        })

      assert run!(conn, "SELECT library.book { title }") == [%{"title" => "Direct Child"}]
    end
  end

  describe "PARENT/SIBLINGS/ANCESTORS" do
    setup do
      conn =
        Conn.new(%{
          ["library"] => [%{"name" => "Main", "region" => "north"}],
          ["library", "fiction"] => [%{"name" => "Fiction"}],
          ["library", "nonfiction"] => [%{"name" => "Non-Fiction"}],
          ["library", "fiction", "book"] => [
            %{"title" => "Dune"},
            %{"title" => "Foundation"}
          ]
        })

      %{conn: conn}
    end

    test "PARENT resolves to the row one level up, projected through its own body", %{conn: conn} do
      assert run!(conn, "SELECT library.fiction.book { title, PARENT { name } }") == [
               %{"title" => "Dune", "parent" => %{"name" => "Fiction"}},
               %{"title" => "Foundation", "parent" => %{"name" => "Fiction"}}
             ]
    end

    test "PARENT is nil at the root, where there's nothing to drop the last segment to", %{
      conn: conn
    } do
      assert run!(conn, "SELECT library { name, PARENT { name } }") ==
               [%{"name" => "Main", "parent" => nil}]
    end

    test "PARENT is nil when the parent key itself doesn't exist at all in the document" do
      conn2 = Conn.new(%{["standalone", "leaf"] => [%{"title" => "Orphan"}]})

      assert run!(conn2, "SELECT standalone.leaf { title, PARENT { name } }") ==
               [%{"title" => "Orphan", "parent" => nil}]
    end

    test "SIBLINGS resolves every row sharing the same parent, excluding the row's own key", %{
      conn: conn
    } do
      assert run!(conn, "SELECT library { name, SIBLINGS { name } }") == [
               %{"name" => "Main", "siblings" => []}
             ]

      # ["library", "fiction"] and ["library", "nonfiction"] are true
      # siblings of each other (same parent prefix ["library"]).
      [fiction_row] = run!(conn, "SELECT library.fiction { name, SIBLINGS { name } }")
      assert fiction_row["siblings"] == [%{"name" => "Non-Fiction"}]
    end

    test "SIBLINGS includes every row at a sibling key, not just the first, when a key holds several",
         %{conn: conn} do
      conn2 =
        Conn.new(
          Map.put(conn.data, ["library", "fiction", "magazine"], [%{"title" => "Sci-Fi Mag"}])
        )

      [book_row | _] =
        run!(
          conn2,
          "SELECT library.fiction.book WHERE title = \"Dune\" { title, SIBLINGS { title } }"
        )

      assert book_row["siblings"] == [%{"title" => "Sci-Fi Mag"}]
    end

    test "ANCESTORS returns one row per level, nearest first, root last", %{conn: conn} do
      [book_row | _] =
        run!(
          conn,
          "SELECT library.fiction.book WHERE title = \"Dune\" { title, ANCESTORS { name } }"
        )

      assert book_row["ancestors"] == [%{"name" => "Fiction"}, %{"name" => "Main"}]
    end

    test "ANCESTORS is an empty list at the root, where there are no levels above it", %{
      conn: conn
    } do
      assert run!(conn, "SELECT library { name, ANCESTORS { name } }") ==
               [%{"name" => "Main", "ancestors" => []}]
    end

    test "nesting PARENT inside PARENT wraps rather than flattening, by design" do
      conn =
        Conn.new(%{
          ["a"] => [%{"label" => "root"}],
          ["a", "b"] => [%{"label" => "mid"}],
          ["a", "b", "c"] => [%{"label" => "leaf"}]
        })

      assert run!(conn, "SELECT a.b.c { PARENT { PARENT { label } } }") == [
               %{"parent" => %{"parent" => %{"label" => "root"}}}
             ]
    end

    test "PARENT/SIBLINGS/ANCESTORS together in one query" do
      conn =
        Conn.new(%{
          ["a"] => [%{"label" => "root"}],
          ["a", "b"] => [%{"label" => "mid"}],
          ["a", "c"] => [%{"label" => "mid-sibling"}],
          ["a", "b", "d"] => [%{"label" => "leaf"}]
        })

      assert run!(
               conn,
               "SELECT a.b.d { label, PARENT { label }, SIBLINGS { label }, ANCESTORS { label } }"
             ) == [
               %{
                 "label" => "leaf",
                 "parent" => %{"label" => "mid"},
                 "siblings" => [],
                 "ancestors" => [%{"label" => "mid"}, %{"label" => "root"}]
               }
             ]
    end
  end

  describe "scope limits, stated as clear errors rather than undefined behavior" do
    test "a pseudo-field alongside GROUP BY is declined explicitly" do
      conn = Conn.new(%{["nodes"] => [%{"category" => "a", "title" => "x"}]})

      {:ok, query} =
        Scry.Document.parse("SELECT nodes GROUP BY category { category, PARENT { category } }")

      assert {:error, {:unsupported, :pseudo_field_with_group_by}} = Executor.run(query, conn)
    end

    test "a CombinedQuery (UNION/etc.) is declined explicitly this round" do
      conn = Conn.new(%{["a"] => [%{"x" => 1}], ["b"] => [%{"x" => 2}]})
      {:ok, query} = Scry.Document.parse("SELECT a { x } UNION SELECT b { x }")

      assert {:error, {:unsupported, :combined_query}} = Executor.run(query, conn)
    end
  end

  describe "the lang_spec.md §8.3 worked example, run for real" do
    test "WHERE + LIMIT + PARENT (nested) + ANCESTORS, exactly as the spec's own query reads" do
      conn =
        Conn.new(%{
          ["library"] => [%{"name" => "Main Library", "region" => "north"}],
          ["library", "catalog"] => [%{"name" => "Fiction Catalog"}],
          ["library", "catalog", "shelves"] => [%{"code" => "S1"}],
          ["library", "catalog", "shelves", "shelf"] => [%{"category" => "sci-fi"}],
          ["library", "catalog", "shelves", "shelf", "books"] => [%{"count" => 2}],
          ["library", "catalog", "shelves", "shelf", "books", "book"] => [
            %{"title" => "Dune", "price" => 45, "available" => true},
            %{"title" => "Cheap Book", "price" => 10, "available" => true},
            %{"title" => "Unavailable", "price" => 99, "available" => false}
          ]
        })

      # Commas added between body items -- comma-on-newline is a known,
      # separately-tracked gap in core's own grammar, not something
      # this package introduces or fixes (see the parity test's own
      # identical case for the citation).
      query_text = ~s"""
      SELECT library.catalog.shelves.shelf.books.book
          WHERE price > 30 AND available = true LIMIT 5
      {
          title,
          PARENT { PARENT { category } },
          ANCESTORS { region }
      }
      """

      assert run!(conn, query_text) == [
               %{
                 "title" => "Dune",
                 "parent" => %{"parent" => %{"category" => "sci-fi"}},
                 "ancestors" => [
                   %{"region" => nil},
                   %{"region" => nil},
                   %{"region" => nil},
                   %{"region" => nil},
                   %{"region" => "north"}
                 ]
               }
             ]
    end
  end
end
