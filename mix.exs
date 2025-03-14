defmodule Membrane.Transcoder.Plugin.Mixfile do
  use Mix.Project

  @version "0.2.0"
  @github_url "https://github.com/membraneframework/membrane_transcoder_plugin"

  def project do
    [
      app: :membrane_transcoder_plugin,
      version: @version,
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),

      # hex
      description: "Transcoder plugin for Membrane Framework",
      package: package(),

      # docs
      name: "Membrane Transcoder plugin",
      source_url: @github_url,
      docs: docs(),
      homepage_url: "https://membrane.stream"
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:membrane_core, "~> 1.1"},
      {:membrane_opus_plugin, "~> 0.20.3"},
      {:membrane_aac_plugin, "~> 0.19.0"},
      {:membrane_aac_fdk_plugin, "~> 0.18.0"},
      {:membrane_vpx_plugin, "~> 0.3.0"},
      {:membrane_h26x_plugin, "~> 0.10.0"},
      {:membrane_h264_ffmpeg_plugin, "~> 0.32.0"},
      {:membrane_h265_ffmpeg_plugin, "~> 0.4.2"},
      {:membrane_ffmpeg_swresample_plugin, "~> 0.20.0"},
      {:membrane_timestamp_queue, "~> 0.2.2"},
      {:membrane_h264_format, "~> 0.6.1"},
      {:membrane_h265_format, "~> 0.2.0"},
      {:membrane_vp8_format, "~> 0.5.0"},
      {:membrane_opus_format, "~> 0.3.0"},
      {:membrane_aac_format, "~> 0.8.0"},
      {:membrane_funnel_plugin, "~> 0.9.1"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:dialyxir, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, ">= 0.0.0", only: :dev, runtime: false},
      {:membrane_file_plugin, "~> 0.17.2", only: :test},
      {:membrane_raw_audio_parser_plugin, "~> 0.4.0", only: :test},
      {:membrane_ivf_plugin, "~> 0.8.0", only: :test}
    ]
  end

  defp dialyzer() do
    opts = [
      flags: [:error_handling]
    ]

    if System.get_env("CI") == "true" do
      # Store PLTs in cacheable directory for CI
      [plt_local_path: "priv/plts", plt_core_path: "priv/plts"] ++ opts
    else
      opts
    end
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membrane.stream"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      formatters: ["html"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [Membrane.Template]
    ]
  end
end
