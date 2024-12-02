defmodule Membrane.Transcoder.IntegrationTest do
  use ExUnit.Case
  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.{H264, H265, VP8, RawVideo, AAC, Opus, RawAudio}
  alias Membrane.Testing.Pipeline
  alias Membrane.Transcoder.Support.Preprocessors

  @video_inputs [
    %{input_format: H264, input_file: "video.h264", preprocess: &Preprocessors.parse_h264/1},
    %{input_format: RawVideo, input_file: "video.h264", preprocess: &Preprocessors.decode_h264/1},
    %{input_format: H265, input_file: "video.h265", preprocess: &Preprocessors.parse_h265/1},
    %{input_format: VP8, input_file: "video.ivf", preprocess: &Preprocessors.parse_vp8/1}
  ]
  @video_outputs [RawVideo, H264, H265, VP8]
  @video_cases for input <- @video_inputs,
                   output <- @video_outputs,
                   do: Map.put(input, :output_format, output)

  @raw_audio_stream_format %RawAudio{
    channels: 2,
    sample_rate: 44_100,
    sample_format: :s24le
  }

  @audio_inputs [
    # %{
    #   input_format: RawAudio,
    #   input_file: "audio.raw",
    #   preprocess: &Preprocessors.parse_raw_audio(&1, @raw_audio_stream_format)
    # },
    %{input_format: AAC, input_file: "audio.aac", preprocess: &Preprocessors.parse_aac/1},
    %{input_format: Opus, input_file: "audio.opus", preprocess: &Preprocessors.parse_opus/1}
  ]
  @audio_outputs [RawAudio, AAC, Opus]
  @audio_cases for input <- @audio_inputs,
                   output <- @audio_outputs,
                   do: Map.put(input, :output_format, output)

  @test_cases @video_cases ++ @audio_cases

  Enum.map(@test_cases, fn test_case ->
    test "if #{inspect(test_case.input_format)} stream is transcoded to #{inspect(test_case.output_format)}" do
      pid = Pipeline.start_link_supervised!()

      spec =
        child(%Membrane.File.Source{
          location: Path.join("./test/fixtures", unquote(test_case.input_file))
        })
        |> then(unquote(test_case.preprocess))
        |> child(%Membrane.Transcoder{output_stream_format: unquote(test_case.output_format)})
        |> child(:sink, Membrane.Testing.Sink)

      Pipeline.execute_actions(pid, spec: spec)

      assert_sink_stream_format(pid, :sink, %unquote(test_case.output_format){})
      Pipeline.terminate(pid)
    end
  end)
end
