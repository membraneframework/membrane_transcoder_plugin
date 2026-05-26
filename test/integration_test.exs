defmodule Membrane.Transcoder.IntegrationTest do
  use ExUnit.Case
  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  require Membrane.Pad

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
        |> child(:transcoder, %Membrane.Transcoder{
          output_stream_format: unquote(test_case.output_format),
          assumed_input_stream_format: override_input_stream_format
        })
        |> via_out(Membrane.Pad.ref(:output, 0))
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
    @tag :tmp_dir
    test "transcoder produces stable output for #{inspect(test_case.input_format)} -> H264 with native acceleration",
         %{tmp_dir: tmp_dir} do
      fixture_path =
        Path.join(
          @vk_fixtures_dir,
          "#{unquote(test_case.input_format) |> Module.split() |> List.last() |> String.downcase()}_to_h264.h264"
        )

      actual = run_transcoder_to_file(unquote(Macro.escape(test_case)), :if_available, tmp_dir)

      assert byte_size(actual) > 0, "transcoder produced empty output"
      assert_or_regenerate_fixture!(actual, fixture_path)
    end
  end)

  defp run_transcoder_to_file(test_case, native_acceleration, tmp_dir) do
    tmp_path = tmp_path(tmp_dir, "vk_transcoder")

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
      |> via_out(Membrane.Pad.ref(:output, 0))
      |> child(:sink, %Membrane.File.Sink{location: tmp_path})

    Testing.Pipeline.execute_actions(pid, spec: spec)
    assert_end_of_stream(pid, :sink, :input, 30_000)
    Testing.Pipeline.terminate(pid)

    bytes = File.read!(tmp_path)
    File.rm(tmp_path)
    bytes
  end

  defp transcode_to_bytes(input_file, preprocess, output_format, tmp_dir) do
    tmp_path = tmp_path(tmp_dir, "ref")
    pid = Testing.Pipeline.start_link_supervised!()

    spec =
      child(%Membrane.File.Source{location: input_file})
      |> then(preprocess)
      |> child(:transcoder, %Membrane.Transcoder{output_stream_format: output_format})
      |> via_out(Membrane.Pad.ref(:output, 0))
      |> child(:sink, %Membrane.File.Sink{location: tmp_path})

    Testing.Pipeline.execute_actions(pid, spec: spec)
    assert_end_of_stream(pid, :sink, :input, 30_000)
    Testing.Pipeline.terminate(pid)

    bytes = File.read!(tmp_path)
    File.rm(tmp_path)
    bytes
  end

  defp tmp_path(tmp_dir, prefix) do
    Path.join(tmp_dir, "#{prefix}_#{:erlang.unique_integer([:positive])}")
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

      spec = [
        child(:source, %FormatSource{format: format})
        |> child(:transcoder, %Membrane.Transcoder{
          output_stream_format: output_format,
          transcoding_policy: transcoding_policy
        }),
        get_child(:transcoder)
        |> via_out(Membrane.Pad.ref(:output, 0))
        |> child(:sink, Testing.Sink)
      ]

      pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)

      Process.sleep(500)

      case format do
        %H264{} -> [:h264_encoder, :h264_decoder]
        %AAC{} -> [:aac_encoder, :aac_decoder]
      end
      |> Enum.each(fn base_name ->
        get_child_result =
          Testing.Pipeline.get_child_pid(
            pipeline,
            [:transcoder, {"output_0", base_name}]
          )

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
      |> via_out(Membrane.Pad.ref(:output, 0))
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

    spec = [
      child(%Membrane.File.Source{location: "./test/fixtures/video.h264"})
      |> then(&Preprocessors.parse_h264/1)
      |> child(:transcoder, %Membrane.Transcoder{
        output_stream_format: H264,
        transcoding_policy: :always,
        native_acceleration: :never
      }),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 0))
      |> child(:sink, Testing.Sink)
    ]

    Testing.Pipeline.execute_actions(pid, spec: spec)
    assert_sink_stream_format(pid, :sink, _format)

    assert {:ok, _pid} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {"output_0", :h264_decoder}])

    assert {:ok, _pid} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {"output_0", :h264_encoder}])

    assert {:error, :child_not_found} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {"output_0", :vk_h264_decoder}])

    assert {:error, :child_not_found} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {"output_0", :vk_h264_encoder}])

    Testing.Pipeline.terminate(pid)
  end

  @tag :tmp_dir
  test "multivariant output: two outputs with different formats from H264 input", %{
    tmp_dir: tmp_dir
  } do
    ref_h264 =
      transcode_to_bytes("./test/fixtures/video.h264", &Preprocessors.parse_h264/1, H264, tmp_dir)

    ref_h265 =
      transcode_to_bytes("./test/fixtures/video.h264", &Preprocessors.parse_h264/1, H265, tmp_dir)

    pid = Testing.Pipeline.start_link_supervised!()
    h264_tmp = tmp_path(tmp_dir, "mv")
    h265_tmp = tmp_path(tmp_dir, "mv")

    spec = [
      child(%Membrane.File.Source{location: "./test/fixtures/video.h264"})
      |> then(&Preprocessors.parse_h264/1)
      |> child(:transcoder, Membrane.Transcoder),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 0), options: [output_stream_format: H264])
      |> child(:sink_h264, %Membrane.File.Sink{location: h264_tmp}),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 1), options: [output_stream_format: H265])
      |> child(:sink_h265, %Membrane.File.Sink{location: h265_tmp})
    ]

    Testing.Pipeline.execute_actions(pid, spec: spec)
    assert_end_of_stream(pid, :sink_h264, :input, 30_000)
    assert_end_of_stream(pid, :sink_h265, :input, 30_000)
    Testing.Pipeline.terminate(pid)

    mv_h264 = File.read!(h264_tmp)
    mv_h265 = File.read!(h265_tmp)
    File.rm(h264_tmp)
    File.rm(h265_tmp)

    assert mv_h264 == ref_h264
    assert mv_h265 == ref_h265
  end

  @tag :tmp_dir
  test "multivariant output: two video outputs with different resolutions", %{tmp_dir: tmp_dir} do
    ref_h264 =
      transcode_to_bytes("./test/fixtures/video.h264", &Preprocessors.parse_h264/1, H264, tmp_dir)

    ref_vp8 =
      transcode_to_bytes("./test/fixtures/video.h264", &Preprocessors.parse_h264/1, VP8, tmp_dir)

    pid = Testing.Pipeline.start_link_supervised!()
    h264_tmp = tmp_path(tmp_dir, "mv")
    vp8_tmp = tmp_path(tmp_dir, "mv")

    spec = [
      child(%Membrane.File.Source{location: "./test/fixtures/video.h264"})
      |> then(&Preprocessors.parse_h264/1)
      |> child(:transcoder, Membrane.Transcoder),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 0), options: [output_stream_format: H264])
      |> child(:sink_h264, %Membrane.File.Sink{location: h264_tmp}),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 1), options: [output_stream_format: VP8])
      |> child(:sink_vp8, %Membrane.File.Sink{location: vp8_tmp})
    ]

    Testing.Pipeline.execute_actions(pid, spec: spec)
    assert_end_of_stream(pid, :sink_h264, :input, 30_000)
    assert_end_of_stream(pid, :sink_vp8, :input, 30_000)
    Testing.Pipeline.terminate(pid)

    mv_h264 = File.read!(h264_tmp)
    mv_vp8 = File.read!(vp8_tmp)
    File.rm(h264_tmp)
    File.rm(vp8_tmp)

    assert mv_h264 == ref_h264
    assert mv_vp8 == ref_vp8
  end

  test "multivariant output: per-output transcoding_policy is respected" do
    pid = Testing.Pipeline.start_link_supervised!()

    spec = [
      child(:source, %FormatSource{format: %H264{alignment: :au, stream_structure: :annexb}})
      |> child(:transcoder, Membrane.Transcoder),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 0),
        options: [
          output_stream_format: %H264{alignment: :au, stream_structure: :avc1},
          transcoding_policy: :always
        ]
      )
      |> child(:sink_always, Testing.Sink),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 1),
        options: [
          output_stream_format: %H264{alignment: :au, stream_structure: :avc1},
          transcoding_policy: :if_needed
        ]
      )
      |> child(:sink_if_needed, Testing.Sink)
    ]

    Testing.Pipeline.execute_actions(pid, spec: spec)

    Process.sleep(500)

    # :always output should have encoder/decoder with "output_0_" prefix
    assert {:ok, _pid} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {"output_0", :h264_decoder}])

    assert {:ok, _pid} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {"output_0", :h264_encoder}])

    # :if_needed output should NOT have encoder/decoder (same format type)
    assert {:error, :child_not_found} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {"output_1", :h264_decoder}])

    assert {:error, :child_not_found} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {"output_1", :h264_encoder}])

    Testing.Pipeline.terminate(pid)
  end

  @tag :tmp_dir
  test "multivariant output: three audio outputs with different formats", %{tmp_dir: tmp_dir} do
    ref_aac =
      transcode_to_bytes("./test/fixtures/audio.aac", &Preprocessors.parse_aac/1, AAC, tmp_dir)

    ref_opus =
      transcode_to_bytes("./test/fixtures/audio.aac", &Preprocessors.parse_aac/1, Opus, tmp_dir)

    ref_mp3 =
      transcode_to_bytes(
        "./test/fixtures/audio.aac",
        &Preprocessors.parse_aac/1,
        MPEGAudio,
        tmp_dir
      )

    pid = Testing.Pipeline.start_link_supervised!()
    aac_tmp = tmp_path(tmp_dir, "mv")
    opus_tmp = tmp_path(tmp_dir, "mv")
    mp3_tmp = tmp_path(tmp_dir, "mv")

    spec = [
      child(%Membrane.File.Source{location: "./test/fixtures/audio.aac"})
      |> then(&Preprocessors.parse_aac/1)
      |> child(:transcoder, Membrane.Transcoder),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 0), options: [output_stream_format: AAC])
      |> child(:sink_aac, %Membrane.File.Sink{location: aac_tmp}),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 1), options: [output_stream_format: Opus])
      |> child(:sink_opus, %Membrane.File.Sink{location: opus_tmp}),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 2), options: [output_stream_format: MPEGAudio])
      |> child(:sink_mp3, %Membrane.File.Sink{location: mp3_tmp})
    ]

    Testing.Pipeline.execute_actions(pid, spec: spec)
    assert_end_of_stream(pid, :sink_aac, :input, 30_000)
    assert_end_of_stream(pid, :sink_opus, :input, 30_000)
    assert_end_of_stream(pid, :sink_mp3, :input, 30_000)
    Testing.Pipeline.terminate(pid)

    mv_aac = File.read!(aac_tmp)
    mv_opus = File.read!(opus_tmp)
    mv_mp3 = File.read!(mp3_tmp)
    File.rm(aac_tmp)
    File.rm(opus_tmp)
    File.rm(mp3_tmp)

    assert mv_aac == ref_aac
    assert mv_opus == ref_opus
    assert mv_mp3 == ref_mp3
  end

  test "multivariant output: per-output options override bin-level options" do
    pid = Testing.Pipeline.start_link_supervised!()

    spec = [
      child(%Membrane.File.Source{location: "./test/fixtures/video.h264"})
      |> then(&Preprocessors.parse_h264/1)
      |> child(:transcoder, %Membrane.Transcoder{output_stream_format: H264}),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 0))
      |> child(:sink_default, Testing.Sink),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 1), options: [output_stream_format: H265])
      |> child(:sink_override, Testing.Sink)
    ]

    Testing.Pipeline.execute_actions(pid, spec: spec)

    assert_sink_stream_format(pid, :sink_default, format_default, 10_000)
    assert format_default.__struct__ == H264

    assert_sink_stream_format(pid, :sink_override, format_override, 10_000)
    assert format_override.__struct__ == H265

    Testing.Pipeline.terminate(pid)
  end

  @tag :vulkan
  test "uses VKVideo decoder and encoder when native_acceleration is :if_available" do
    pid = Testing.Pipeline.start_link_supervised!()

    spec = [
      child(%Membrane.File.Source{location: "./test/fixtures/video.h264"})
      |> then(&Preprocessors.parse_h264/1)
      |> child(:transcoder, %Membrane.Transcoder{
        output_stream_format: H264,
        transcoding_policy: :always,
        native_acceleration: :if_available
      }),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 0))
      |> child(:sink, Testing.Sink)
    ]

    Testing.Pipeline.execute_actions(pid, spec: spec)
    assert_sink_stream_format(pid, :sink, _format)

    assert {:ok, _pid} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {"output_0", :vk_h264_decoder}])

    assert {:ok, _pid} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {"output_0", :vk_h264_encoder}])

    assert {:error, :child_not_found} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {"output_0", :h264_decoder}])

    assert {:error, :child_not_found} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {"output_0", :h264_encoder}])

    Testing.Pipeline.terminate(pid)
  end
end
