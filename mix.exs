defmodule PhoenixKitAgent.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_agent"

  def project do
    [
      app: :phoenix_kit_agent,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "AI agent module for PhoenixKit — per-user chats with tool calling over the PhoenixKit API registry",
      package: package(),
      dialyzer: [plt_add_apps: [:phoenix_kit, :phoenix_kit_ai]],
      name: "PhoenixKitAgent",
      source_url: @source_url,
      docs: docs(),
      test_coverage: [
        ignore_modules: [
          ~r/^PhoenixKitAgent\.Test\./,
          PhoenixKitAgent.DataCase
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :phoenix_kit, :phoenix_kit_ai]]
  end

  def cli do
    [preferred_envs: ["test.setup": :test, "test.reset": :test]]
  end

  # test/support/ is compiled only in :test so DataCase and TestRepo
  # don't leak into the published package.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "format",
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci"
      ],
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitAgent.Test.Repo"
      ],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitAgent.Test.Repo",
        "test.setup"
      ]
    ]
  end

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against a
  # local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit or
  # PHOENIX_KIT_AI_PATH=../phoenix_kit_ai. Unset => the published pin, so
  # mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour and the Settings API.
      # 2.62.2 is the core this module is specified and verified against.
      # Bounded as `>= floor and < 3.0.0` (not a three-segment `~>`) so every
      # later 2.x core minor stays admissible for hosts running this module.
      pk_dep(:phoenix_kit, ">= 2.62.2 and < 3.0.0"),

      # Model calls, endpoints, credentials, budget and the request journal
      # come from phoenix_kit_ai; this module only adds the chat layer.
      pk_dep(:phoenix_kit_ai, "~> 0.25"),

      # LiveView is needed for the admin pages (Phase 1).
      {:phoenix_live_view, "~> 1.1"},

      # Optional rustler pin so the transitive `mdex_native` NIF (via phoenix_kit,
      # a test dependency) can source-build on hosts where its precompiled variant
      # doesn't match the local NIF version.
      {:rustler, ">= 0.0.0", optional: true},

      # Documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitAgent",
      source_ref: "v#{@version}"
    ]
  end
end
