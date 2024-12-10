Mix.install([
  :membrane_file_plugin,
  :membrane_ivf_plugin,
  {:membrane_transcoder_plugin, path: __DIR__ |> Path.join("..") |> Path.expand()}
])

defmodule Example do
  alias Membrane.RCPipeline
  require Membrane.RCPipeline, as: RCPipeline
  import Membrane.ChildrenSpec

  def convert(input_file, output_file) do
    pipeline = RCPipeline.start_link!()

    spec =
      child(%Membrane.File.Source{
        location: input_file
      })
      |> child(:deserializer, Membrane.IVF.Deserializer)
      |> child(:transcoder, %Membrane.Transcoder{output_stream_format: Membrane.H264})
      |> child(:sink, %Membrane.File.Sink{location: output_file})

    RCPipeline.subscribe(pipeline, _any)
    RCPipeline.exec_actions(pipeline, spec: spec)
    RCPipeline.await_end_of_stream(pipeline, :sink)
    RCPipeline.terminate(pipeline)
  end
end

File.mkdir("tmp")
Example.convert(Path.join("./test/fixtures", "video.ivf"), Path.join("./tmp", "video.h264"))
