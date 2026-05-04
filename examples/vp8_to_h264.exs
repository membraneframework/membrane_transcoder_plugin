use_native = System.argv() |> Enum.member?("--native")

vk_dep =
  if use_native &&
       match?({_, 0}, System.cmd("pkg-config", ["--exists", "vulkan"], stderr_to_stdout: true)) do
    [{:membrane_vk_video_plugin, "~> 0.2.0"}]
  else
    []
  end

Mix.install(
  vk_dep ++
    [
      :membrane_file_plugin,
      :membrane_ivf_plugin,
      {:membrane_transcoder_plugin, path: __DIR__ |> Path.join("..") |> Path.expand()}
    ]
)

defmodule Example do
  alias Membrane.{H264, RCPipeline}
  require RCPipeline

  import Membrane.ChildrenSpec

  def convert(input_file, output_file, native_acceleration) do
    pipeline = RCPipeline.start_link!()

    spec =
      child(%Membrane.File.Source{
        location: input_file
      })
      |> child(:deserializer, Membrane.IVF.Deserializer)
      |> child(:transcoder, %Membrane.Transcoder{
        output_stream_format: H264,
        native_acceleration: native_acceleration
      })
      |> child(:sink, %Membrane.File.Sink{location: output_file})

    RCPipeline.subscribe(pipeline, _any)
    RCPipeline.exec_actions(pipeline, spec: spec)
    RCPipeline.await_end_of_stream(pipeline, :sink)
    RCPipeline.terminate(pipeline)
  end
end

File.mkdir_p!("tmp")

if use_native && !Membrane.Transcoder.vulkan_available?() do
  raise "Vulkan is not available. Cannot run with --native flag."
end

acceleration = if use_native, do: :if_available, else: :never

output_file = Path.join(__DIR__, "tmp/video.h264")

if use_native do
  IO.puts("Vulkan available: true")
  IO.puts("Using native_acceleration: :if_available")
end

Example.convert(
  Path.join(__DIR__, "../test/fixtures/video_vp8.ivf"),
  output_file,
  acceleration
)

IO.puts("Done. Output written to #{output_file}")
