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
  @video_outputs [RawVideo, {RawVideo, pixel_format: :RGB}, H264, H265, VP8, VP9]
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

  # Only H264 outputs exercise the Vulkan-accelerated encode path. Each case
  # has a committed fixture under test/fixtures/vk_outputs/ that pins the
  # expected bitstream produced on a Vulkan-capable machine. To (re)generate
  # the fixtures, run `REGEN_VK_FIXTURES=1 mix test --include vulkan` once on
  # such a machine and commit the resulting files.
  @vk_video_cases for input <- @video_inputs,
                      do: Map.put(input, :output_format, H264)

  @vk_fixtures_dir "./test/fixtures/vk_outputs"

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

      case unquote(test_case.output_format) do
        {module, opts} when is_atom(module) ->
          assert_sink_stream_format(pid, :sink, %^module{} = received_format)

          for {key, value} <- opts do
            assert Map.get(received_format, key) == value
          end

        module when is_atom(module) ->
          assert_sink_stream_format(pid, :sink, received_format)
          assert received_format.__struct__ == module
      end

      Testing.Pipeline.terminate(pid)
    end
  end)

  Enum.map(@vk_video_cases, fn test_case ->
    @tag :vulkan
    test "transcoder produces stable output for #{inspect(test_case.input_format)} -> H264 with native acceleration" do
      fixture_path =
        Path.join(
          @vk_fixtures_dir,
          "#{unquote(test_case.input_format) |> Module.split() |> List.last() |> String.downcase()}_to_h264.bin"
        )

      actual = run_transcoder_to_file(unquote(Macro.escape(test_case)), :if_available)

      assert byte_size(actual) > 0, "transcoder produced empty output"
      assert_or_regenerate_fixture!(actual, fixture_path)
    end
  end)

  defp run_transcoder_to_file(test_case, native_acceleration) do
    tmp_path =
      Path.join(System.tmp_dir!(), "vk_transcoder_#{:erlang.unique_integer([:positive])}")

    pid = Testing.Pipeline.start_link_supervised!()

    spec =
      child(%Membrane.File.Source{
        location: Path.join("./test/fixtures", test_case.input_file)
      })
      |> then(test_case.preprocess)
      |> child(:transcoder, %Membrane.Transcoder{
        output_stream_format: test_case.output_format,
        native_acceleration: native_acceleration
      })
      |> child(:sink, %Membrane.File.Sink{location: tmp_path})

    Testing.Pipeline.execute_actions(pid, spec: spec)
    assert_end_of_stream(pid, :sink, :input, 30_000)
    Testing.Pipeline.terminate(pid)

    bytes = File.read!(tmp_path)
    File.rm(tmp_path)
    bytes
  end

  defp assert_or_regenerate_fixture!(actual, fixture_path) do
    if System.get_env("REGEN_VK_FIXTURES") == "1" do
      File.mkdir_p!(Path.dirname(fixture_path))
      File.write!(fixture_path, actual)
      IO.puts("Regenerated fixture: #{fixture_path}")
    else
      case File.read(fixture_path) do
        {:ok, expected} ->
          assert :crypto.hash(:sha256, actual) == :crypto.hash(:sha256, expected),
                 "output does not match fixture #{fixture_path}"

        {:error, :enoent} ->
          flunk("""
          Missing fixture #{fixture_path}.
          Run `REGEN_VK_FIXTURES=1 mix test --include vulkan` on a Vulkan-capable \
          machine to generate it, then commit the resulting file.
          """)
      end
    end
  end

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
    for format <- [
          %AAC{channels: 1, sample_rate: 44_100, profile: :LC},
          %H264{alignment: :au, stream_structure: :annexb}
        ],
        transcoding_policy <- [:always, :if_needed, :never] do
      output_format =
        case format do
          %H264{} = h264 -> %H264{h264 | stream_structure: :avc1}
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

  test "uses FFmpeg decoder and encoder when native_acceleration is :never" do
    pid = Testing.Pipeline.start_link_supervised!()

    spec =
      child(%Membrane.File.Source{location: "./test/fixtures/video.h264"})
      |> then(&Preprocessors.parse_h264/1)
      |> child(:transcoder, %Membrane.Transcoder{
        output_stream_format: H264,
        transcoding_policy: :always,
        native_acceleration: :never
      })
      |> child(:sink, Testing.Sink)

    Testing.Pipeline.execute_actions(pid, spec: spec)
    assert_sink_stream_format(pid, :sink, _format)

    assert {:ok, _pid} = Testing.Pipeline.get_child_pid(pid, [:transcoder, :h264_decoder])
    assert {:ok, _pid} = Testing.Pipeline.get_child_pid(pid, [:transcoder, :h264_encoder])

    assert {:error, :child_not_found} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, :vk_h264_decoder])

    assert {:error, :child_not_found} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, :vk_h264_encoder])

    Testing.Pipeline.terminate(pid)
  end

  @tag :vulkan
  test "uses VKVideo decoder and encoder when native_acceleration is :if_available" do
    pid = Testing.Pipeline.start_link_supervised!()

    spec =
      child(%Membrane.File.Source{location: "./test/fixtures/video.h264"})
      |> then(&Preprocessors.parse_h264/1)
      |> child(:transcoder, %Membrane.Transcoder{
        output_stream_format: H264,
        transcoding_policy: :always,
        native_acceleration: :if_available
      })
      |> child(:sink, Testing.Sink)

    Testing.Pipeline.execute_actions(pid, spec: spec)
    assert_sink_stream_format(pid, :sink, _format)

    assert {:ok, _pid} = Testing.Pipeline.get_child_pid(pid, [:transcoder, :vk_h264_decoder])
    assert {:ok, _pid} = Testing.Pipeline.get_child_pid(pid, [:transcoder, :vk_h264_encoder])

    assert {:error, :child_not_found} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, :h264_decoder])

    assert {:error, :child_not_found} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, :h264_encoder])

    Testing.Pipeline.terminate(pid)
  end
end
