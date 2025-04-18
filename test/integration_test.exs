defmodule Membrane.Transcoder.IntegrationTest do
  use ExUnit.Case
  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.{AAC, H264, H265, MPEGAudio, Opus, RawAudio, RawVideo, VP8, VP9}
  alias Membrane.Testing
  alias Membrane.Transcoder.Support.Preprocessors

  @video_inputs [
    %{input_format: H264, input_file: "video.h264", preprocess: &Preprocessors.parse_h264/1},
    %{input_format: RawVideo, input_file: "video.h264", preprocess: &Preprocessors.decode_h264/1},
    %{input_format: H265, input_file: "video.h265", preprocess: &Preprocessors.parse_h265/1},
    %{input_format: VP8, input_file: "video_vp8.ivf", preprocess: &Preprocessors.parse_vpx/1},
    %{input_format: VP9, input_file: "video_vp9.ivf", preprocess: &Preprocessors.parse_vpx/1}
  ]
  @video_outputs [RawVideo, H264, H265, VP8, VP9]
  @video_cases for input <- @video_inputs,
                   output <- @video_outputs,
                   do: Map.put(input, :output_format, output)

  @audio_inputs [
    %{
      input_format: RawAudio,
      input_file: "audio.raw",
      preprocess: &Preprocessors.parse_raw_audio/1
    },
    %{input_format: AAC, input_file: "audio.aac", preprocess: &Preprocessors.parse_aac/1},
    %{input_format: Opus, input_file: "audio.opus", preprocess: &Preprocessors.parse_opus/1},
    %{input_format: MPEGAudio, input_file: "audio.mp3", preprocess: &Preprocessors.noop/1}
  ]
  @audio_outputs [RawAudio, AAC, Opus, MPEGAudio]
  @audio_cases for input <- @audio_inputs,
                   output <- @audio_outputs,
                   do: Map.put(input, :output_format, output)

  @test_cases @video_cases ++ @audio_cases

  Enum.map(@test_cases, fn test_case ->
    test "if transcoder supports #{inspect(test_case.input_format)} input and #{inspect(test_case.output_format)} output" do
      pid = Testing.Pipeline.start_link_supervised!()

      override_input_stream_format =
        if unquote(test_case.input_format) == MPEGAudio,
          do: %Membrane.RemoteStream{content_format: MPEGAudio, type: :packetized}

      spec =
        child(%Membrane.File.Source{
          location: Path.join("./test/fixtures", unquote(test_case.input_file))
        })
        |> then(unquote(test_case.preprocess))
        |> child(%Membrane.Transcoder{
          output_stream_format: unquote(test_case.output_format),
          assumed_input_stream_format: override_input_stream_format
        })
        |> child(:sink, Testing.Sink)

      Testing.Pipeline.execute_actions(pid, spec: spec)

      assert_sink_stream_format(pid, :sink, %unquote(test_case.output_format){})
      Testing.Pipeline.terminate(pid)
    end
  end)

  defmodule FormatSource do
    use Membrane.Source

    def_output_pad :output, accepted_format: _any, flow_control: :push
    def_options format: []

    @impl true
    def handle_init(_ctx, opts), do: {[], opts |> Map.from_struct()}

    @impl true
    def handle_playing(_ctx, state),
      do: {[stream_format: {:output, state.format}], state}
  end

  test "if encoder and decoder are spawned or not, depending on the value of `transcoding_policy` option" do
    for format <- [%AAC{channels: 1}, %H264{alignment: :au, stream_structure: :annexb}],
        transcoding_policy <- [:always, :if_needed, :never] do
      output_format =
        case format do
          %H264{} -> %H264{format | stream_structure: :avc1}
          %AAC{} -> format
        end

      spec =
        child(:source, %FormatSource{format: format})
        |> child(:transcoder, %Membrane.Transcoder{
          output_stream_format: output_format,
          transcoding_policy: transcoding_policy
        })
        |> child(:sink, Testing.Sink)

      pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)

      Process.sleep(500)

      case format do
        %H264{} -> [:h264_encoder, :h264_decoder]
        %AAC{} -> [:aac_encoder, :aac_decoder]
      end
      |> Enum.each(fn child_name ->
        get_child_result = Testing.Pipeline.get_child_pid(pipeline, [:transcoder, child_name])

        if transcoding_policy == :always do
          assert {:ok, child_pid} = get_child_result
          assert is_pid(child_pid)
        else
          assert {:error, :child_not_found} = get_child_result
        end
      end)

      Testing.Pipeline.terminate(pipeline)
    end
  end

  test "if transcoder raises when `transcoding_policy` is set to `:never` and formats don't match" do
    spec =
      child(:source, %FormatSource{format: %H264{alignment: :au, stream_structure: :annexb}})
      |> child(:transcoder, %Membrane.Transcoder{
        output_stream_format: VP8,
        transcoding_policy: :never
      })
      |> child(:sink, Testing.Sink)

    {:ok, supervisor, pipeline} = Testing.Pipeline.start(spec: [])
    supervisor_ref = Process.monitor(supervisor)
    pipeline_ref = Process.monitor(pipeline)

    Testing.Pipeline.execute_actions(pipeline, spec: spec)

    assert_receive {:DOWN, ^pipeline_ref, :process, _pid,
                    {:membrane_child_crash, :transcoder, {%RuntimeError{}, _stacktrace}}}

    assert_receive {:DOWN, ^supervisor_ref, :process, _pid, _reason}
  end
end
