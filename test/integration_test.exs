defmodule Membrane.Transcoder.IntegrationTest do
  use ExUnit.Case
  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad

  alias Membrane.{AAC, H264, H265, MPEGAudio, Opus, RawAudio, RawVideo, VP8, VP9}
  alias Membrane.Testing
  alias Membrane.Transcoder.Support.Preprocessors
  alias Membrane.Transcoder.Video.{ConstantBitrate, VariableBitrate}

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
  @scaled_fixtures_dir "./test/fixtures/scaled_outputs"

  # video.h264 is 320x180; scale tests use half resolution
  @scale_sw_cases [
    %{
      input_format: H264,
      input_file: "video.h264",
      preprocess: &Preprocessors.parse_h264/1,
      output_format: %H264{width: 160, height: 90},
      label: "h264_to_h264",
      ext: "h264",
      resolution: "160x90"
    },
    %{
      input_format: H264,
      input_file: "video.h264",
      preprocess: &Preprocessors.parse_h264/1,
      output_format: {RawVideo, [width: 160, height: 90]},
      label: "h264_to_rawvideo",
      ext: "yuv",
      resolution: "160x90"
    },
    %{
      input_format: RawVideo,
      input_file: "video.h264",
      preprocess: &Preprocessors.decode_h264/1,
      output_format: %H264{width: 160, height: 90},
      label: "rawvideo_to_h264",
      ext: "h264",
      resolution: "160x90"
    },
    %{
      input_format: RawVideo,
      input_file: "video.h264",
      preprocess: &Preprocessors.decode_h264/1,
      output_format: {RawVideo, [width: 160, height: 90]},
      label: "rawvideo_to_rawvideo",
      ext: "yuv",
      resolution: "160x90"
    }
  ]

  @scale_vk_cases [
    %{
      input_format: H264,
      input_file: "video.h264",
      preprocess: &Preprocessors.parse_h264/1,
      output_format: %H264{width: 160, height: 90},
      label: "h264_to_h264",
      ext: "h264",
      resolution: "160x90"
    }
  ]

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

  defp assert_or_regenerate_scaled_fixture!(actual, fixture_path) do
    if System.get_env("REGEN_SCALED_FIXTURES") == "1" do
      File.mkdir_p!(Path.dirname(fixture_path))
      File.write!(fixture_path, actual)
      IO.puts("Regenerated fixture: #{fixture_path}")
    else
      case File.read(fixture_path) do
        {:ok, expected} ->
          assert actual == expected,
                 "output does not match fixture #{fixture_path}"

        {:error, :enoent} ->
          flunk("""
          Missing fixture #{fixture_path}.
          Run `REGEN_SCALED_FIXTURES=1 mix test` to generate it, then commit the resulting file.
          """)
      end
    end
  end

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
      |> child(:transcoder, Membrane.Transcoder)
      |> via_out(Membrane.Pad.ref(:output, 0), options: [output_stream_format: output_format])
      |> child(:sink, %Membrane.File.Sink{location: tmp_path})

    Testing.Pipeline.execute_actions(pid, spec: spec)
    assert_end_of_stream(pid, :sink, :input, 30_000)
    Testing.Pipeline.terminate(pid)

    bytes = File.read!(tmp_path)
    File.rm(tmp_path)
    bytes
  end

  defp transcode_to_bytes_with_bitrate(
         input_file,
         preprocess,
         output_format,
         bitrate,
         native_acceleration,
         tmp_dir
       ) do
    tmp_path = tmp_path(tmp_dir, "bitrate")
    pid = Testing.Pipeline.start_link_supervised!()

    spec =
      child(%Membrane.File.Source{location: input_file})
      |> then(preprocess)
      |> child(:transcoder, %Membrane.Transcoder{
        output_stream_format: output_format,
        transcoding_policy: :always,
        native_acceleration: native_acceleration,
        bitrate: bitrate
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
            [:transcoder, {base_name, {0, :output}}]
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
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {:h264_decoder, {0, :output}}])

    assert {:ok, _pid} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {:h264_encoder, {0, :output}}])

    assert {:error, :child_not_found} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {:vk_h264_decoder, {0, :output}}])

    assert {:error, :child_not_found} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {:vk_h264_encoder, {0, :output}}])

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
  test "multivariant output: two video outputs with different codecs", %{tmp_dir: tmp_dir} do
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
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {:h264_decoder, {0, :output}}])

    assert {:ok, _pid} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {:h264_encoder, {0, :output}}])

    # :if_needed output should NOT have encoder/decoder (same format type)
    assert {:error, :child_not_found} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {:h264_decoder, {1, :output}}])

    assert {:error, :child_not_found} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {:h264_encoder, {1, :output}}])

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

  Enum.map(@scale_sw_cases, fn test_case ->
    @tag :tmp_dir
    test "scales #{test_case.label} to 160x90 (software)", %{tmp_dir: tmp_dir} do
      fixture_path =
        Path.join(
          @scaled_fixtures_dir,
          "sw_#{unquote(test_case.label)}_#{unquote(test_case.resolution)}.#{unquote(test_case.ext)}"
        )

      actual = run_transcoder_to_file(unquote(Macro.escape(test_case)), :never, tmp_dir)

      assert byte_size(actual) > 0, "transcoder produced empty output"
      assert_or_regenerate_scaled_fixture!(actual, fixture_path)
    end
  end)

  Enum.map(@scale_vk_cases, fn test_case ->
    @tag :vulkan
    @tag :tmp_dir
    test "scales #{test_case.label} to 160x90 (vulkan)", %{tmp_dir: tmp_dir} do
      fixture_path =
        Path.join(
          @scaled_fixtures_dir,
          "vk_#{unquote(test_case.label)}_#{unquote(test_case.resolution)}.#{unquote(test_case.ext)}"
        )

      actual = run_transcoder_to_file(unquote(Macro.escape(test_case)), :if_available, tmp_dir)

      assert byte_size(actual) > 0, "transcoder produced empty output"
      assert_or_regenerate_scaled_fixture!(actual, fixture_path)
    end
  end)

  test "output format width/height drives RawVideo output dimensions" do
    pid = Testing.Pipeline.start_link_supervised!()

    spec =
      child(%Membrane.File.Source{location: "./test/fixtures/video.h264"})
      |> then(&Preprocessors.parse_h264/1)
      |> child(:transcoder, %Membrane.Transcoder{
        output_stream_format: {RawVideo, [width: 160, height: 90]}
      })
      |> via_out(Membrane.Pad.ref(:output, 0))
      |> child(:sink, Testing.Sink)

    Testing.Pipeline.execute_actions(pid, spec: spec)

    assert_sink_stream_format(pid, :sink, %RawVideo{width: 160, height: 90}, 10_000)

    Testing.Pipeline.terminate(pid)
  end

  test "per-output format with resolution overrides bin-level format" do
    pid = Testing.Pipeline.start_link_supervised!()

    spec = [
      child(%Membrane.File.Source{location: "./test/fixtures/video.h264"})
      |> then(&Preprocessors.parse_h264/1)
      |> child(:transcoder, %Membrane.Transcoder{
        output_stream_format: {RawVideo, [width: 320, height: 180]}
      }),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 0))
      |> child(:sink_default, Testing.Sink),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 1),
        options: [output_stream_format: {RawVideo, [width: 160, height: 90]}]
      )
      |> child(:sink_scaled, Testing.Sink)
    ]

    Testing.Pipeline.execute_actions(pid, spec: spec)

    assert_sink_stream_format(pid, :sink_default, %RawVideo{width: 320, height: 180}, 10_000)
    assert_sink_stream_format(pid, :sink_scaled, %RawVideo{width: 160, height: 90}, 10_000)

    Testing.Pipeline.terminate(pid)
  end

  test "resolution pad option scales video independently of output_stream_format" do
    pid = Testing.Pipeline.start_link_supervised!()

    spec = [
      child(%Membrane.File.Source{location: "./test/fixtures/video.h264"})
      |> then(&Preprocessors.parse_h264/1)
      |> child(:transcoder, %Membrane.Transcoder{output_stream_format: RawVideo}),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 0))
      |> child(:sink_default, Testing.Sink),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 1), options: [resolution: {160, 90}])
      |> child(:sink_scaled, Testing.Sink)
    ]

    Testing.Pipeline.execute_actions(pid, spec: spec)

    assert_sink_stream_format(pid, :sink_default, %RawVideo{width: 320, height: 180}, 10_000)
    assert_sink_stream_format(pid, :sink_scaled, %RawVideo{width: 160, height: 90}, 10_000)

    Testing.Pipeline.terminate(pid)
  end

  test "bin-level resolution applies to all outputs without per-pad override" do
    pid = Testing.Pipeline.start_link_supervised!()

    spec =
      child(%Membrane.File.Source{location: "./test/fixtures/video.h264"})
      |> then(&Preprocessors.parse_h264/1)
      |> child(:transcoder, %Membrane.Transcoder{
        output_stream_format: RawVideo,
        resolution: {160, 90}
      })
      |> via_out(Membrane.Pad.ref(:output, 0))
      |> child(:sink, Testing.Sink)

    Testing.Pipeline.execute_actions(pid, spec: spec)

    assert_sink_stream_format(pid, :sink, %RawVideo{width: 160, height: 90}, 10_000)

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
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {:vk_h264_decoder, {0, :output}}])

    assert {:ok, _pid} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {:vk_h264_encoder, {0, :output}}])

    assert {:error, :child_not_found} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {:h264_decoder, {0, :output}}])

    assert {:error, :child_not_found} =
             Testing.Pipeline.get_child_pid(pid, [:transcoder, {:h264_encoder, {0, :output}}])

    Testing.Pipeline.terminate(pid)
  end

  @tag :tmp_dir
  test "bitrate conversion produces different output sizes", %{tmp_dir: tmp_dir} do
    # Transcode the same input with different bitrates and verify output sizes differ
    low_bitrate = %ConstantBitrate{
      bitrate: 100_000,
      virtual_buffer_size: Membrane.Time.seconds(2)
    }

    high_bitrate = %ConstantBitrate{
      bitrate: 5_000_000,
      virtual_buffer_size: Membrane.Time.seconds(2)
    }

    low_output =
      transcode_to_bytes_with_bitrate(
        "./test/fixtures/video.h264",
        &Preprocessors.parse_h264/1,
        H264,
        low_bitrate,
        :never,
        tmp_dir
      )

    high_output =
      transcode_to_bytes_with_bitrate(
        "./test/fixtures/video.h264",
        &Preprocessors.parse_h264/1,
        H264,
        high_bitrate,
        :never,
        tmp_dir
      )

    # Low bitrate (100k) should produce output significantly smaller than high bitrate (5M)
    # With a 50x bitrate difference, we expect the file size ratio to be substantial
    # We check that low output is less than 25% of high output size
    assert byte_size(low_output) > 0, "Low bitrate output is empty"
    assert byte_size(high_output) > 0, "High bitrate output is empty"

    low_size = byte_size(low_output)
    high_size = byte_size(high_output)
    ratio = low_size / high_size

    assert ratio < 0.25,
           "Low bitrate output (#{low_size} bytes) should be less than 25% of high bitrate output (#{high_size} bytes), but ratio is #{ratio}"
  end

  @tag :vulkan
  @tag :tmp_dir
  test "bitrate conversion with vulkan produces different output sizes", %{tmp_dir: tmp_dir} do
    # Transcode the same input with different bitrates using Vulkan and verify output sizes differ
    low_bitrate = %ConstantBitrate{
      bitrate: 100_000,
      virtual_buffer_size: Membrane.Time.seconds(2)
    }

    high_bitrate = %ConstantBitrate{
      bitrate: 5_000_000,
      virtual_buffer_size: Membrane.Time.seconds(2)
    }

    low_output =
      transcode_to_bytes_with_bitrate(
        "./test/fixtures/video.h264",
        &Preprocessors.parse_h264/1,
        H264,
        low_bitrate,
        :if_available,
        tmp_dir
      )

    high_output =
      transcode_to_bytes_with_bitrate(
        "./test/fixtures/video.h264",
        &Preprocessors.parse_h264/1,
        H264,
        high_bitrate,
        :if_available,
        tmp_dir
      )

    # Low bitrate (100k) should produce output significantly smaller than high bitrate (5M)
    assert byte_size(low_output) > 0, "Low bitrate output is empty"
    assert byte_size(high_output) > 0, "High bitrate output is empty"

    low_size = byte_size(low_output)
    high_size = byte_size(high_output)
    ratio = low_size / high_size

    # With Vulkan acceleration, the compression ratio may vary more, so we use a more lenient threshold
    assert ratio < 0.30,
           "Low bitrate output (#{low_size} bytes) should be less than 30% of high bitrate output (#{high_size} bytes), but ratio is #{ratio}"
  end

  @tag :tmp_dir
  test "bitrate conversion with format change produces valid output", %{tmp_dir: tmp_dir} do
    bitrate = %ConstantBitrate{bitrate: 1_000_000, virtual_buffer_size: Membrane.Time.seconds(2)}

    # Transcode H264 to H265 with bitrate
    output =
      transcode_to_bytes_with_bitrate(
        "./test/fixtures/video.h264",
        &Preprocessors.parse_h264/1,
        H265,
        bitrate,
        :never,
        tmp_dir
      )

    assert byte_size(output) > 0, "Output is empty"
  end

  @tag :tmp_dir
  test "variable bitrate produces valid output", %{tmp_dir: tmp_dir} do
    bitrate = %VariableBitrate{
      average_bitrate: 1_000_000,
      max_bitrate: 2_000_000,
      virtual_buffer_size: Membrane.Time.seconds(2)
    }

    output =
      transcode_to_bytes_with_bitrate(
        "./test/fixtures/video.h264",
        &Preprocessors.parse_h264/1,
        H264,
        bitrate,
        :never,
        tmp_dir
      )

    assert byte_size(output) > 0, "Variable bitrate output is empty"
  end

  @tag :tmp_dir
  test "per-output bitrate produces different sizes", %{tmp_dir: tmp_dir} do
    low_bitrate = %ConstantBitrate{
      bitrate: 100_000,
      virtual_buffer_size: Membrane.Time.seconds(2)
    }

    high_bitrate = %ConstantBitrate{
      bitrate: 3_000_000,
      virtual_buffer_size: Membrane.Time.seconds(2)
    }

    pid = Testing.Pipeline.start_link_supervised!()
    low_tmp = tmp_path(tmp_dir, "mv_low")
    high_tmp = tmp_path(tmp_dir, "mv_high")

    spec = [
      child(%Membrane.File.Source{location: "./test/fixtures/video.h264"})
      |> then(&Preprocessors.parse_h264/1)
      |> child(:transcoder, %Membrane.Transcoder{
        output_stream_format: H264,
        transcoding_policy: :always,
        native_acceleration: :never
      }),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 0), options: [bitrate: low_bitrate])
      |> child(:sink_low, %Membrane.File.Sink{location: low_tmp}),
      get_child(:transcoder)
      |> via_out(Membrane.Pad.ref(:output, 1), options: [bitrate: high_bitrate])
      |> child(:sink_high, %Membrane.File.Sink{location: high_tmp})
    ]

    Testing.Pipeline.execute_actions(pid, spec: spec)
    assert_end_of_stream(pid, :sink_low, :input, 30_000)
    assert_end_of_stream(pid, :sink_high, :input, 30_000)
    Testing.Pipeline.terminate(pid)

    low_output = File.read!(low_tmp)
    high_output = File.read!(high_tmp)
    File.rm(low_tmp)
    File.rm(high_tmp)

    assert byte_size(low_output) > 0, "Low bitrate multivariant output is empty"
    assert byte_size(high_output) > 0, "High bitrate multivariant output is empty"

    low_size = byte_size(low_output)
    high_size = byte_size(high_output)
    ratio = low_size / high_size

    # With 30x bitrate difference (100k vs 3M), expect low to be less than 50% of high

    assert ratio < 0.50,
           "Low bitrate multivariant output (#{low_size} bytes) should be less than 50% of high bitrate (#{high_size} bytes), but ratio is #{ratio}"
  end
end
