defmodule Scry.Document.MixProject do
  use Mix.Project

  @version "0.1.0"

  # `mix precommit` includes `test` as a step; without this, Mix runs
  # the whole alias chain (including `mix test`) in :dev, and `mix test`
  # itself refuses to run outside :test when invoked as a sub-task
  # rather than the top-level command.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def project do
    [
      app: :scry_document,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Scry.Document",
      docs: docs(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      # `:ichor` needs to be listed explicitly here now that it's
      # `runtime: false` (only [:dev, :test]) -- dialyxir's default PLT
      # scan draws on the compiled app's own `:applications` list,
      # which a `runtime: false` dependency is deliberately excluded
      # from, even though it's still genuinely present and compiled in
      # this (`:test`) env, and `Scry.Document.Grammar`/the generator
      # script still reference its types/functions directly.
      dialyzer: [plt_add_apps: [:mix, :ichor], ignore_warnings: ".dialyzer_ignore.exs"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # === SCRY CORE ===
      # A local path dependency, not a Hex version constraint, since
      # scry_core isn't published to Hex yet -- this package composes
      # its own grammar fragment against core's own unanalyzed grammar
      # (Scry.Core.Grammar.compile_unanalyzed/0, Scry.Core.GrammarCompose.
      # merge/2), so it's the real dependency, not test-only. Switch to
      # a `~> x.y` Hex requirement once scry_core is actually published.
      {:scry_core, path: "../scry_core"},

      # === ICHOR (grammar compiler) ===
      # Same reasoning as scry_time_series's own identical comment:
      # `ichor` was originally unscoped here for grammar composition,
      # fixed the same way `scry_core`/`scry_time_series` both were --
      # `Scry.Document.parse/1` runs queries through `Scry.Document.
      # Grammar.Compiled`, a checked-in, pre-generated module (`priv/gen/
      # generate_compiled_grammar.exs` is its generator, run by hand).
      # The generated module only calls `ichor_runtime`, never `ichor`
      # -- back to `only: [:dev, :test]`, matching `ichor`'s own
      # documented recommendation for exactly this case.
      {:ichor_runtime, "~> 0.2"},
      {:ichor, "~> 0.2", only: [:dev, :test], runtime: false},

      # === CODE QUALITY & STATIC ANALYSIS ===
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      # Credo is invoked via `MIX_ENV=test mix credo`
      # Dialyzer is invoked via `MIX_ENV=test mix dialyzer`
      # Sobelow is invoked via `MIX_ENV=test mix sobelow`
      # Coveralls is invoked via `MIX_ENV=test mix coveralls

      # === TESTING ===
      {:stream_data, "~> 1.1", only: [:dev, :test]},

      # === DEVELOPMENT TOOLING ===
      # Mix, and Hex are built-in (no deps needed)
      {:ex_doc, "~> 0.40", only: [:dev], runtime: false}
      # ExDoc is invoked via `MIX_ENV=dev mix docs`
    ]
  end

  # Fast/cheap checks first so a broken commit fails quickly; dialyzer
  # (slowest, especially its first PLT build) runs last.
  defp aliases do
    [
      precommit: [
        "format",
        "compile --warnings-as-errors",
        "credo --strict",
        # `--skip`: honors `@sobelow_skip` annotations on specific
        # functions (AGENTS.md: a low-confidence finding needs a
        # targeted, justified skip, never a blanket suppression) --
        # without this flag Sobelow ignores the annotation entirely and
        # reports the finding anyway. Matches scry_core's/scry_time_series's
        # own alias -- this package has the identical `File.read(path)`
        # shape (`Scry.Document.Grammar.compile/0`) that needs it.
        "sobelow --skip",
        "test",
        "dialyzer"
      ]
    ]
  end

  defp description do
    "The document kind for Scry -- grammar fragment and composition " <>
      "against scry_core for DEEP/PARENT/SIBLINGS/ANCESTORS, plus a real Scry.Document.Executor."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/joetjen/scry_document"},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/joetjen/scry_document",
      source_ref: "v#{@version}",
      extras: extras()
    ]
  end

  defp extras do
    [
      "README.md",
      "CHANGELOG.md",
      "LICENSE"
    ]
  end
end
