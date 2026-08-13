# scry_document

The `document` kind for [Scry](https://github.com/joetjen/scry)
(lang_spec.md §8.3) — a `scry_<kind>` package (impl_spec.md §2), the
second real one built against
[`scry_core`](https://github.com/joetjen/scry_core)'s EP1/EP2
extension-point composition machinery, and the first to fill *two*
extension points at once: `select_ep1a` for `DEEP`, and `body_item_ep1`
for `PARENT`/`SIBLINGS`/`ANCESTORS` (the XPath `parent::`/sibling-axis/
`ancestor::` equivalents) — a "scoped pseudo-field" (EP1(c)) shape no
real package had exercised before this one; only a fixture fragment in
`scry_core`'s own test suite had (`Scry.Core.GrammarComposeTest`'s
`@graph_like_fragment`, standing in for `scry_graph`'s own `VIA`).

## Scope and two real findings from building this

**`DEEP`'s own execution semantics aren't specified in lang_spec.md**
beyond "recursive descent, vs. one child level," with no worked
example ever using it. Decided directly with this repo's own
maintainer, not inferred: `DEEP` means XPath `//` semantics — `SELECT
a. ... .z DEEP` matches a `z`-named node reachable at *any* depth
beneath `a`, not requiring the literal intermediate segments given.
`Scry.Document.Executor`'s own moduledoc has the full mechanics.

**No existing engine can represent a hierarchical document at all** —
found before writing a line of this package's own code.
`Scry.Core.Query.source` is typed `[String.t()]`, but every real engine
(`scry_engine_inmemory`/`ets`/`exqlite`/`postgrex`) and the shared test
fixtures hard-assume a *single*-segment source key; two of the four
adapters do `[table] = source` and would raise `MatchError` on a real
multi-segment source today. So this package reuses the *exact* existing
`%{[String.t(), ...] => [row]}` shape every engine's own `conn` already
has, just letting keys have more than one segment and treating segment
order as tree position — no new storage primitive, a data convention
instead (`Scry.Document.Conn`'s own moduledoc has the full reasoning).
There's no real document-store adapter for this kind yet either
(`impl_spec.md` §6 names no day-one product for it) — `Scry.Document.
Executor` operates directly against a `Scry.Document.Conn.t()` rather
than dispatching through `Scry.Core.EngineBehaviour`, since no existing
behaviour callback receives the whole keyed document space `DEEP`/
`PARENT`/`SIBLINGS`/`ANCESTORS` all need.

**Deliberately out of scope this round**: a pseudo-field combined with
`GROUP BY` (an aggregated result no longer corresponds to one specific
document node — neither spec says what that should mean) and
`%Scry.Core.CombinedQuery{}` (`UNION`/etc.) both return a clear
`{:error, {:unsupported, ...}}` rather than an undefined result.

Source: <https://github.com/joetjen/scry_document>. Specs live in the
separate [`scry`](https://github.com/joetjen/scry) repository; the
composition machinery this composes against lives in
[`scry_core`](https://github.com/joetjen/scry_core).

## Usage

```elixir
alias Scry.Document.{Conn, Executor}

conn =
  Conn.new(%{
    ["library"] => [%{"name" => "Main Library", "region" => "north"}],
    ["library", "catalog", "shelves", "shelf"] => [%{"category" => "sci-fi"}],
    ["library", "catalog", "shelves", "shelf", "books", "book"] => [
      %{"title" => "Dune", "price" => 45, "available" => true}
    ]
  })

{:ok, query} =
  Scry.Document.parse(~s"""
  SELECT library.catalog.shelves.shelf.books.book
      WHERE price > 30 AND available = true LIMIT 5
  {
      title,
      PARENT { PARENT { category } },
      ANCESTORS { region }
  }
  """)

{:ok, cursor} = Executor.run(query, conn)
Scry.Core.Cursor.to_list(cursor)
# [%{"title" => "Dune",
#    "parent" => %{"parent" => %{"category" => "sci-fi"}},
#    "ancestors" => [%{"region" => nil}, %{"region" => nil}, %{"region" => nil}, %{"region" => nil}, %{"region" => "north"}]}]
```

The commas between `title`/`PARENT { ... }`/`ANCESTORS { ... }` above
are shown for clarity but no longer required — core's own `body_list`
grammar now accepts a bare newline as an item separator too (a comma
is still always valid, and a trailing comma before the closing `}` is
now permitted as well). `lang_spec.md`'s own §8.3 worked example, which
omits the commas, now parses as written.

**Nesting one pseudo-field inside another wraps, it doesn't flatten**
— `PARENT { PARENT { category } }` produces `%{"parent" => %{"parent"
=> %{"category" => ...}}}`, shown above, not a flattened `%{"category"
=> ...}`. Each pseudo-field is an ordinary named body item, wrapping
whatever its own body projects to under its own name — there's nothing
pseudo-field-specific about that rule, so nesting one inside another
doesn't get special-cased away. Neither spec states an expected output
shape for this, so it's a deliberate, documented reading of an
otherwise-open question.

`ANCESTORS` returns one row per ancestor *level*, nearest first, root
last — a field simply absent higher up the tree (`region`, above,
which only exists on the `library` row) projects as `nil` at every
other level, the same leniency an ordinary missing field already has.

A query with no `DEEP`/`PARENT`/`SIBLINGS`/`ANCESTORS` at all parses
(and executes) exactly the way `Scry.Core.parse/1`/`Scry.Core.
Executor.run/4` already handle it — the merged grammar still runs
every one of core's own rules unchanged; only the two extension points
this package fills are new. `Scry.Document.Executor.run/3` returns a
lazy `Scry.Core.Cursor.t()`, the same widened contract `Scry.Core.
Executor.run/3,4`/`Scry.TimeSeries.Executor.run/5` already have.

## Installation

```elixir
def deps do
  [
    {:scry_document, "~> 0.1.0"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_document>.
- Latest `main` is built and deployed automatically by
  [`.github/workflows/docs.yml`](.github/workflows/docs.yml) to
  [GitHub Pages](https://joetjen.github.io/scry_document/) on every push to `main`.
