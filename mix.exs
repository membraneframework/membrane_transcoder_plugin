defmodule Membrane.Transcoder.Plugin.Mixfile do
  use Mix.Project

  @version "0.3.4"
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
      description: "High-level bin for automatic media stream transcoding via a declarative API.",
      package: package(),

      # docs
      name: "Membrane Transcoder plugin",
      source_url: @github_url,
      docs: docs(),
      homepage_url: "https://membrane.stream",
      aliases: [docs: ["docs", &prepend_llms_links/1]]
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
      {:membrane_core, "~> 1.2 and >= 1.2.1"},
      {:membrane_opus_plugin, "~> 0.20.3"},
      {:membrane_aac_plugin, "~> 0.19.0"},
      {:membrane_aac_fdk_plugin, "~> 0.18.0"},
      {:membrane_vpx_plugin, "~> 0.4.0"},
      {:membrane_h26x_plugin, "~> 0.10.0"},
      {:membrane_h264_ffmpeg_plugin, "~> 0.32.0"},
      {:membrane_h265_ffmpeg_plugin, "~> 0.4.2"},
      {:membrane_ffmpeg_swresample_plugin, "~> 0.20.0"},
      {:membrane_ffmpeg_swscale_plugin, "~> 0.16.2"},
      {:membrane_timestamp_queue, "~> 0.2.2"},
      {:membrane_h264_format, "~> 0.6.1"},
      {:membrane_h265_format, "~> 0.2.0"},
      {:membrane_vp8_format, "~> 0.5.0"},
      {:membrane_opus_format, "~> 0.3.0"},
      {:membrane_aac_format, "~> 0.8.0"},
      {:membrane_funnel_plugin, "~> 0.9.1"},
      {:membrane_mpegaudio_format, "~> 0.3.0"},
      {:membrane_mp3_mad_plugin, "~> 0.18.4"},
      {:membrane_mp3_lame_plugin, "~> 0.18.3"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
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
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [Membrane.Template]
    ]
  end

  defp prepend_llms_links(_) do
    output_dir = docs()[:output] || "doc"
    path = Path.join(output_dir, "llms.txt")

    if File.exists?(path) do
      existing = File.read!(path)

      footer = """


      ## See Also

      - [Membrane Framework AI Skill](https://hexdocs.pm/membrane_core/skill.md)
      - [Membrane Core](https://hexdocs.pm/membrane_core/llms.txt)
      """

      File.write!(path, String.trim_trailing(existing) <> footer)
    else
      IO.warn("#{path} not found — llms.txt was not generated, check your ex_doc configuration")
    end
  end
end
