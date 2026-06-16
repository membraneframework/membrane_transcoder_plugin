defmodule Membrane.Transcoder.Video do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Logger
  alias Membrane.{ChildrenSpec, H264, H265, RawVideo, RemoteStream, VP8, VP9}
  alias Membrane.FFmpeg.SWScale
  alias Membrane.Transcoder.Video.{ConstantBitrate, VariableBitrate}

  @type video_stream_format :: VP8.t() | VP9.t() | H264.t() | H265.t() | RawVideo.t()

  defguardp is_raw_video_format(format)
            when is_struct(format) and format.__struct__ == RawVideo

  defguardp is_h26x_format(format)
            when is_struct(format) and
                   (format.__struct__ in [H264, H265] or
                      (format.__struct__ == RemoteStream and
                         format.content_format in [H264, H265]))

  defguardp is_vpx_format(format)
            when is_struct(format) and
                   (format.__struct__ in [VP8, VP9] or
                      (format.__struct__ == RemoteStream and
                         format.content_format in [VP8, VP9] and
                         format.type == :packetized))

  defguard is_video_format(format)
           when is_h26x_format(format) or
                  is_vpx_format(format) or
                  is_raw_video_format(format)

  @spec plug_video_transcoding(
          ChildrenSpec.builder(),
          video_stream_format(),
          video_stream_format(),
          :always | :if_needed | :never,
          boolean(),
          map()
        ) :: ChildrenSpec.builder()
  def plug_video_transcoding(
        builder,
        input_format,
        output_format,
        transcoding_policy,
        use_hardware_acceleration?,
        output_spec
      )
      when is_video_format(input_format) and is_video_format(output_format) do
    do_plug_video_transcoding(
      builder,
      input_format,
      output_format,
      transcoding_policy,
      use_hardware_acceleration?,
      output_spec
    )
  end

  defp do_plug_video_transcoding(
         builder,
         %RemoteStream{content_format: h26x},
         output_format,
         transcoding_policy,
         use_hardware_acceleration?,
         output_spec
       )
       when h26x in [H264, H265] do
    do_plug_video_transcoding(
      builder,
      struct!(h26x),
      output_format,
      transcoding_policy,
      use_hardware_acceleration?,
      output_spec
    )
  end

  defp do_plug_video_transcoding(
         builder,
         %H264{},
         %H264{} = output_format,
         transcoding_policy,
         _use_hardware_acceleration?,
         output_spec
       )
       when transcoding_policy in [:if_needed, :never] do
    builder
    |> child(child_name(output_spec.suffix, :h264_parser), %H264.Parser{
      output_stream_structure: stream_structure_type(output_format),
      output_alignment: output_format.alignment
    })
  end

  defp do_plug_video_transcoding(
         builder,
         %H265{},
         %H265{} = output_format,
         transcoding_policy,
         _use_hardware_acceleration?,
         output_spec
       )
       when transcoding_policy in [:if_needed, :never] do
    builder
    |> child(child_name(output_spec.suffix, :h265_parser), %H265.Parser{
      output_stream_structure: stream_structure_type(output_format),
      output_alignment: output_format.alignment
    })
  end

  defp do_plug_video_transcoding(
         builder,
         %RawVideo{} = input_format,
         %RawVideo{} = output_format,
         _transcoding_policy,
         true,
         output_spec
       ) do
    builder
    |> maybe_plug_swscale_converter_vulkan(input_format, output_format, output_spec.suffix)
  end

  defp do_plug_video_transcoding(
         builder,
         %RawVideo{} = input_format,
         %RawVideo{} = output_format,
         _transcoding_policy,
         false,
         output_spec
       ) do
    builder
    |> maybe_plug_swscale_converter(input_format, output_format, output_spec.suffix)
  end

  defp do_plug_video_transcoding(
         builder,
         %format_module{},
         %format_module{},
         transcoding_policy,
         _use_hardware_acceleration?,
         _output_spec
       )
       when transcoding_policy in [:if_needed, :never] do
    Membrane.Logger.debug("""
    This bin will only forward buffers, as the input stream format is the same type as the output stream format.
    """)

    builder
  end

  defp do_plug_video_transcoding(
         _builder,
         input_format,
         output_format,
         :never,
         _use_hardware_acceleration?,
         _output_spec
       ),
       do:
         raise("""
         Cannot convert input format #{inspect(input_format)} to output format #{inspect(output_format)} \
         with :transcoding_policy option set to :never.
         """)

  defp do_plug_video_transcoding(
         builder,
         input_format,
         output_format,
         _transcoding_policy,
         true,
         output_spec
       ) do
    builder
    |> maybe_plug_parser_and_decoder_vulkan(input_format, output_spec)
    |> maybe_plug_swscale_converter_vulkan(input_format, output_format, output_spec.suffix)
    |> maybe_plug_encoder_and_parser_vulkan(output_format, output_spec)
  end

  defp do_plug_video_transcoding(
         builder,
         input_format,
         output_format,
         _transcoding_policy,
         false,
         output_spec
       ) do
    builder
    |> maybe_plug_parser_and_decoder(input_format, output_spec.suffix)
    |> maybe_plug_swscale_converter(input_format, output_format, output_spec.suffix)
    |> maybe_plug_encoder_and_parser(output_format, output_spec)
  end

  # VK-specific decoder: child name :vk_h264_decoder distinguishes it from FFmpeg's :h264_decoder
  defp maybe_plug_parser_and_decoder_vulkan(builder, %H264{}, output_spec) do
    suffix = output_spec.suffix

    builder
    |> child(child_name(suffix, :h264_input_parser), %H264.Parser{
      output_stream_structure: :annexb,
      output_alignment: :au
    })
    |> child(child_name(suffix, :vk_h264_decoder), Membrane.VKVideo.Decoder)
  end

  defp maybe_plug_parser_and_decoder_vulkan(builder, format, output_spec),
    do: maybe_plug_parser_and_decoder(builder, format, output_spec.suffix)

  defp maybe_plug_parser_and_decoder(builder, %H264{}, suffix) do
    builder
    |> child(child_name(suffix, :h264_input_parser), %H264.Parser{
      output_stream_structure: :annexb,
      output_alignment: :au
    })
    |> child(child_name(suffix, :h264_decoder), %H264.FFmpeg.Decoder{})
  end

  defp maybe_plug_parser_and_decoder(builder, %H265{}, suffix) do
    builder
    |> child(child_name(suffix, :h265_input_parser), %H265.Parser{
      output_stream_structure: :annexb,
      output_alignment: :au
    })
    |> child(child_name(suffix, :h265_decoder), %H265.FFmpeg.Decoder{})
  end

  defp maybe_plug_parser_and_decoder(builder, %vpx{}, suffix) when vpx in [VP8, VP9] do
    decoder_module = Module.concat(vpx, Decoder)
    builder |> child(child_name(suffix, :vp8_decoder), decoder_module)
  end

  defp maybe_plug_parser_and_decoder(
         builder,
         %RemoteStream{content_format: vpx, type: :packetized},
         suffix
       )
       when vpx in [VP8, VP9] do
    decoder_module = Module.concat(vpx, Decoder)
    builder |> child(child_name(suffix, :vp8_decoder), decoder_module)
  end

  defp maybe_plug_parser_and_decoder(builder, %RawVideo{}, _suffix), do: builder

  defp maybe_plug_swscale_converter_vulkan(
         builder,
         %H264{},
         %RawVideo{pixel_format: nil},
         _suffix
       ),
       do: builder

  defp maybe_plug_swscale_converter_vulkan(
         builder,
         %H264{},
         %RawVideo{pixel_format: :NV12},
         _suffix
       ),
       do: builder

  defp maybe_plug_swscale_converter_vulkan(builder, %H264{}, %RawVideo{} = output_format, suffix) do
    builder
    |> child(child_name(suffix, :raw_video_converter), %SWScale.Converter{
      format: output_format.pixel_format
    })
  end

  defp maybe_plug_swscale_converter_vulkan(
         builder,
         %RawVideo{pixel_format: :NV12},
         %H264{},
         _suffix
       ),
       do: builder

  defp maybe_plug_swscale_converter_vulkan(builder, %RawVideo{}, %H264{}, suffix) do
    builder |> child(child_name(suffix, :raw_video_converter), %SWScale.Converter{format: :NV12})
  end

  defp maybe_plug_swscale_converter_vulkan(builder, %H264{}, %H264{}, _suffix), do: builder

  defp maybe_plug_swscale_converter_vulkan(builder, %H264{}, _output_format, suffix) do
    builder
    |> child(child_name(suffix, :raw_video_converter), %SWScale.Converter{format: :I420})
  end

  defp maybe_plug_swscale_converter_vulkan(builder, _input_format, %H264{}, suffix) do
    builder
    |> child(child_name(suffix, :raw_video_converter), %SWScale.Converter{format: :NV12})
  end

  defp maybe_plug_swscale_converter_vulkan(builder, input_format, output_format, suffix),
    do: maybe_plug_swscale_converter(builder, input_format, output_format, suffix)

  defp maybe_plug_swscale_converter(builder, input_format, %RawVideo{} = output_format, suffix) do
    case input_format do
      _any when output_format.pixel_format == nil ->
        builder

      %RawVideo{pixel_format: pixel_format} when pixel_format == output_format.pixel_format ->
        builder

      _input_format ->
        builder
        |> child(child_name(suffix, :raw_video_converter), %SWScale.Converter{
          format: output_format.pixel_format
        })
    end
  end

  defp maybe_plug_swscale_converter(builder, input_format, %h26x{}, suffix)
       when h26x in [H264, H265] do
    case input_format do
      %RawVideo{pixel_format: pixel_format} when pixel_format in [:I420, :I422] ->
        builder

      %h26x{} when h26x in [H264, H265] ->
        builder

      _input_format ->
        builder
        |> child(child_name(suffix, :raw_video_converter), %SWScale.Converter{format: :I420})
    end
  end

  defp maybe_plug_swscale_converter(builder, _input_format, _output_format, _suffix), do: builder

  defp maybe_plug_encoder_and_parser_vulkan(builder, %H264{} = h264, output_spec) do
    suffix = output_spec.suffix
    bitrate = output_spec.bitrate
    rate_control = get_vkvideo_rate_control(bitrate)

    builder
    |> child(child_name(suffix, :vk_h264_encoder), %Membrane.VKVideo.Encoder{
      rate_control: rate_control
    })
    |> child(child_name(suffix, :h264_output_parser), %H264.Parser{
      output_stream_structure: stream_structure_type(h264),
      output_alignment: h264.alignment
    })
  end

  defp maybe_plug_encoder_and_parser_vulkan(builder, format, output_spec),
    do: maybe_plug_encoder_and_parser(builder, format, output_spec)

  defp maybe_plug_encoder_and_parser(builder, %H264{} = h264, output_spec) do
    suffix = output_spec.suffix
    bitrate = output_spec.bitrate
    ffmpeg_params = get_h264_ffmpeg_params(bitrate)

    encoder_params = %H264.FFmpeg.Encoder{
      preset: :ultrafast,
      ffmpeg_params: ffmpeg_params
    }

    # default CRF overrides bitrate param, setting it to -1 disables it
    encoder_params =
      if is_nil(bitrate),
        do: encoder_params,
        else: %{encoder_params | crf: -1}

    builder
    |> child(child_name(suffix, :h264_encoder), encoder_params)
    |> child(child_name(suffix, :h264_output_parser), %H264.Parser{
      output_stream_structure: stream_structure_type(h264),
      output_alignment: h264.alignment
    })
  end

  defp maybe_plug_encoder_and_parser(builder, %H265{} = h265, output_spec) do
    suffix = output_spec.suffix
    bitrate = output_spec.bitrate
    x265_params = get_h265_x265_params(bitrate)

    builder
    |> child(child_name(suffix, :h265_encoder), %H265.FFmpeg.Encoder{
      preset: :ultrafast,
      x265_params: x265_params
    })
    |> child(child_name(suffix, :h265_output_parser), %H265.Parser{
      output_stream_structure: stream_structure_type(h265),
      output_alignment: h265.alignment
    })
  end

  defp maybe_plug_encoder_and_parser(builder, %VP8{}, output_spec) do
    suffix = output_spec.suffix
    bitrate = output_spec.bitrate
    target_bitrate = get_vpx_target_bitrate(bitrate)

    builder
    |> child(child_name(suffix, :vp8_encoder), %VP8.Encoder{
      g_threads: cpu_count(),
      cpu_used: 15,
      rc_target_bitrate: target_bitrate
    })
  end

  defp maybe_plug_encoder_and_parser(builder, %VP9{}, output_spec) do
    suffix = output_spec.suffix
    bitrate = output_spec.bitrate
    target_bitrate = get_vpx_target_bitrate(bitrate)

    builder
    |> child(child_name(suffix, :vp9_encoder), %VP9.Encoder{
      g_threads: cpu_count(),
      cpu_used: 15,
      rc_target_bitrate: target_bitrate
    })
  end

  defp maybe_plug_encoder_and_parser(builder, %RawVideo{}, _output_spec), do: builder

  defp stream_structure_type(%h26x{stream_structure: stream_structure})
       when h26x in [H264, H265] do
    case stream_structure do
      type when type in [:annexb, :avc1, :avc3, :hvc1, :hev1] -> type
      {type, _dcr} when type in [:avc1, :avc3, :hvc1, :hev1] -> type
    end
  end

  defp get_vkvideo_rate_control(nil), do: :encoder_default

  defp get_vkvideo_rate_control(%ConstantBitrate{
         bitrate: bitrate,
         virtual_buffer_size: virtual_buffer_size
       }) do
    {:constant_bitrate,
     %Membrane.VKVideo.Encoder.ConstantBitrate{
       bitrate: bitrate,
       virtual_buffer_size_ms: trunc(virtual_buffer_size / 1_000_000)
     }}
  end

  defp get_vkvideo_rate_control(%VariableBitrate{
         average_bitrate: avg,
         max_bitrate: max,
         virtual_buffer_size: virtual_buffer_size
       }) do
    {:variable_bitrate,
     %Membrane.VKVideo.Encoder.VariableBitrate{
       average_bitrate: avg,
       max_bitrate: max,
       virtual_buffer_size_ms: trunc(virtual_buffer_size / 1_000_000)
     }}
  end

  defp get_h264_ffmpeg_params(nil), do: %{}

  defp get_h264_ffmpeg_params(%ConstantBitrate{bitrate: bitrate, virtual_buffer_size: vbr_ns}) do
    vbr_ms = trunc(vbr_ns / 1_000_000)

    %{
      "b" => Integer.to_string(bitrate),
      "bufsize" => Integer.to_string(trunc(bitrate * vbr_ms / 1000))
    }
  end

  defp get_h264_ffmpeg_params(%VariableBitrate{
         average_bitrate: avg,
         max_bitrate: max,
         virtual_buffer_size: vbr_ns
       }) do
    vbr_ms = trunc(vbr_ns / 1_000_000)

    %{
      "b" => Integer.to_string(avg),
      "maxrate" => Integer.to_string(max),
      "bufsize" => Integer.to_string(trunc(max * vbr_ms / 1000))
    }
  end

  defp get_h265_x265_params(nil), do: ""

  defp get_h265_x265_params(%ConstantBitrate{bitrate: bitrate, virtual_buffer_size: vbr_ns}) do
    vbr_ms = trunc(vbr_ns / 1_000_000)

    "bitrate=#{bitrate}:vbv-bufsize=#{trunc(bitrate * vbr_ms / 1000.0 / 8)}:vbv-maxrate=#{bitrate}"
  end

  defp get_h265_x265_params(%VariableBitrate{
         average_bitrate: avg,
         max_bitrate: max,
         virtual_buffer_size: vbr_ns
       }) do
    vbr_ms = trunc(vbr_ns / 1_000_000)
    "bitrate=#{avg}:vbv-bufsize=#{trunc(avg * vbr_ms / 1000.0 / 8)}:vbv-maxrate=#{max}"
  end

  defp get_vpx_target_bitrate(nil), do: :auto

  defp get_vpx_target_bitrate(%ConstantBitrate{bitrate: bitrate}), do: trunc(bitrate / 1000)

  defp get_vpx_target_bitrate(%VariableBitrate{average_bitrate: avg}), do: trunc(avg / 1000)

  defp cpu_count() do
    cpu_quota = :erlang.system_info(:cpu_quota)

    if cpu_quota != :unknown do
      cpu_quota
    else
      try do
        :erlang.system_info(:logical_processors_online)
      rescue
        _cpu_quota -> :erlang.system_info(:logical_processors_available)
      end
    end
  end

  defp child_name(nil, base), do: base
  defp child_name(suffix, base), do: {base, suffix}
end
