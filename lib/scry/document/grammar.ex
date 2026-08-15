defmodule Scry.Document.Grammar do
  @moduledoc """
  Compiles this package's own `priv/grammar.aether` fragment, merges it
  with core's own grammar (`Scry.Core.Grammar.compile_unanalyzed/0` +
  `Scry.Core.GrammarCompose.merge/2`), and analyzes the result --
  §4's own composition mechanics, exercised here for the
  first time by a real, separate package filling **two** extension
  points at once (`select_ep1a` for `DEEP`, `body_item_ep1` for
  `PARENT`/`SIBLINGS`/`ANCESTORS`), where `scry_time_series` only ever
  needed one.

  **Not** the production parse path -- `Scry.Document.parse/1` calls
  the checked-in, pre-generated `Scry.Document.Grammar.Compiled`
  (`priv/gen/generate_compiled_grammar.exs` is its generator, run by
  hand; never hand-edit the generated file). `compile/0` here stays,
  for the same two reasons `scry_time_series`'s own identical function
  does: the generator script itself needs the merged-but-uncompiled
  grammar, and it's a cheap, direct way to test the merge/composition
  mechanics themselves without round-tripping through codegen.

  Uses `:code.priv_dir/1`, not a path relative to the current working
  directory -- resolves correctly both from this package's own test
  suite and from a downstream adapter depending on this package as an
  ordinary compiled dependency.
  """

  # See Scry.Core.Grammar's own identical `@compile {:no_warn_undefined,
  # ...}` comment for the full reasoning -- `Aether.Parser.parse/2`/
  # `Grammar.Analysis.run/1` are genuinely undefined when this module
  # compiles as a dependency of a package that never declares `ichor`
  # itself, and neither is ever actually called by such a consumer.
  @compile {:no_warn_undefined, {Aether.Parser, :parse, 2}}
  @compile {:no_warn_undefined, {Grammar.Analysis, :run, 1}}

  # See Scry.Core.Grammar's own identical attribute/comment for why this
  # is registered rather than a bare module attribute, and why the
  # Sobelow skip below is justified the same way theirs is.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @doc """
  Parses this package's own fragment, merges it with core's own
  unanalyzed grammar, and runs `Grammar.Analysis` on the merged result.
  """
  @sobelow_skip ["Traversal.FileModule"]
  @spec compile() :: {:ok, Aether.Grammar.t()} | {:error, term()}
  def compile do
    path = grammar_path()

    with {:ok, source} <- File.read(path),
         {:ok, fragment} <- Aether.Parser.parse(source, path),
         {:ok, core} <- Scry.Core.Grammar.compile_unanalyzed(),
         {:ok, merged} <- Scry.Core.GrammarCompose.merge(core, fragment) do
      Grammar.Analysis.run(merged)
    end
  end

  @doc false
  @spec grammar_path() :: String.t()
  def grammar_path, do: Path.join(:code.priv_dir(:scry_document), "grammar.aether")
end
