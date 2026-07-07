Mix.install([
  :membrane_file_plugin,
  {:membrane_transcoder_plugin, path: __DIR__ |> Path.join("..") |> Path.expand()}
])

defmodule Example do
  alias Membrane.{H264, H265, VP8, RCPipeline}
  require RCPipeline
  require Membrane.Pad

  import Membrane.ChildrenSpec

  @doc """
  Transcodes a single H264 input into three output files simultaneously:
    - output 0: H264 (annexb, repackaged — no re-encode)
    - output 1: H265 (transcoded)
    - output 2: VP8  (transcoded)

  Each output pad carries its own `output_stream_format`, `transcoding_policy`, and
  `native_acceleration` options, all resolved independently inside the transcoder bin.
  """
  def run(input_file, h264_output_file, h265_output_file, vp8_output_file) do
    pipeline = RCPipeline.start_link!()

    spec = [
      child(%Membrane.File.Source{location: input_file})
      |> child(:parser, %H264.Parser{
        output_stream_structure: :annexb,
        output_alignment: :au,
        generate_best_effort_timestamps: %{framerate: {30, 1}}
      })
      |> child(:transcoder, Membrane.Transcoder),

      # Output 0 — keep H264, just repackage (no re-encode)
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 0),
        options: [
          output_stream_format: %H264{alignment: :au, stream_structure: :annexb},
          resolution: {320, 160},
          transcoding_policy: :if_needed
        ]
      )
      |> child(:h264_sink, %Membrane.File.Sink{location: h264_output_file}),

      # Output 1 — transcode to H265
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 1),
        options: [
          output_stream_format: H265,
          transcoding_policy: :always
        ]
      )
      |> child(:h265_sink, %Membrane.File.Sink{location: h265_output_file}),

      # Output 2 — transcode to VP8
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 2),
        options: [
          output_stream_format: VP8,
          transcoding_policy: :always
        ]
      )
      |> child(:vp8_sink, %Membrane.File.Sink{location: vp8_output_file})
    ]

    RCPipeline.subscribe(pipeline, _any)
    RCPipeline.exec_actions(pipeline, spec: spec)
    RCPipeline.await_end_of_stream(pipeline, :h264_sink)
    RCPipeline.await_end_of_stream(pipeline, :h265_sink)
    RCPipeline.await_end_of_stream(pipeline, :vp8_sink)
    RCPipeline.terminate(pipeline)
  end
end

File.mkdir_p!(Path.join(__DIR__, "tmp"))

input = Path.join(__DIR__, "../test/fixtures/video.h264")
h264_out = Path.join(__DIR__, "tmp/multivariant_output.h264")
h265_out = Path.join(__DIR__, "tmp/multivariant_output.h265")
vp8_out = Path.join(__DIR__, "tmp/multivariant_output.ivf")

IO.puts("Input:        #{input}")
IO.puts("H264 output:  #{h264_out}")
IO.puts("H265 output:  #{h265_out}")
IO.puts("VP8 output:   #{vp8_out}")
IO.puts("")
Example.run(input, h264_out, h265_out, vp8_out)

IO.puts("Done.")
IO.puts("  #{h264_out} (#{File.stat!(h264_out).size} bytes)")
IO.puts("  #{h265_out} (#{File.stat!(h265_out).size} bytes)")
IO.puts("  #{vp8_out} (#{File.stat!(vp8_out).size} bytes)")
