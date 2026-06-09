defmodule Membrane.Transcoder.Video do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Logger
  require Membrane.Pad
  alias Membrane.{ChildrenSpec, H264, H265, Pad, RawVideo, RemoteStream, VP8, VP9}
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

  # Input format natively produces/consumes NV12 in the VK pipeline (H264 via VK decoder, or raw NV12)
  defguardp is_vk_video_friendly_format(format)
            when is_struct(format, H264) or
                   (is_struct(format, RawVideo) and format.pixel_format == :NV12)

  # No conversion needed when output is RawVideo with no scaling: pixel format is unspecified or already matches
  defguardp raw_video_passthrough(input, out_pf)
            when out_pf == nil or (is_struct(input, RawVideo) and input.pixel_format == out_pf)

  # Input pixel format is compatible with H264/H265 FFmpeg encoder (I420 or I422), or input is already encoded
  defguardp is_x264_friendly_format(input)
            when is_struct(input, H264) or is_struct(input, H265) or
                   (is_struct(input, RawVideo) and input.pixel_format in [:I420, :I422])

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
         %H264{width: nil, height: nil} = output_format,
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
         %H265{width: nil, height: nil} = output_format,
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
         _builder,
         %format_module{},
         %format_module{width: width, height: height},
         :never,
         _use_hardware_acceleration?,
         _suffix
       )
       when not is_nil(width) or not is_nil(height) do
    raise """
    Cannot scale resolution to #{width}x#{height} for #{format_module} \
    with :transcoding_policy set to :never — resolution scaling requires re-encoding.
    """
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
         %format_module{width: nil, height: nil},
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

  # # H264 -> H264 with scaling using VKVideo.Transcoder for hardware-accelerated scaling
  defp do_plug_video_transcoding(
         builder,
         %H264{},
         %H264{width: w, height: h} = output_format,
         transcoding_policy,
         true,
         suffix
       )
       when w != nil and h != nil and
              transcoding_policy != :never do
    builder
    |> plug_h264_input_parser(suffix)
    |> child(child_name(suffix, :vk_transcoder), Membrane.VKVideo.Transcoder)
    |> via_out(Pad.ref(:output, 0),
      options: [
        width: w,
        height: h,
        scaling_algorithm: :bilinear
      ]
    )
    |> plug_output_parser(output_format, suffix)
  end

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
    |> plug_h264_input_parser(suffix)
    |> child(child_name(suffix, :vk_h264_decoder), Membrane.VKVideo.Decoder)
  end

  defp maybe_plug_parser_and_decoder_vulkan(builder, format, output_spec),
    do: maybe_plug_parser_and_decoder(builder, format, output_spec.suffix)

  defp maybe_plug_parser_and_decoder(builder, %H264{}, suffix) do
    builder
    |> plug_h264_input_parser(suffix)
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

  # H264 (VK decoded) → RawVideo: skip converter only when no format change and no scaling requested
  defp maybe_plug_swscale_converter_vulkan(
         builder,
         %H264{},
         %RawVideo{pixel_format: pixel_format, width: nil, height: nil},
         _suffix
       )
       when pixel_format in [nil, :NV12],
       do: builder

  defp maybe_plug_swscale_converter_vulkan(
         builder,
         %H264{},
         %RawVideo{pixel_format: pixel_format} = output_format,
         suffix
       ) do
    builder
    |> child(
      child_name(suffix, :raw_video_converter),
      swscale_converter(pixel_format || :NV12, output_format)
    )
  end

  # → H264: skip when input already produces NV12 (H264 via VK, or RawVideo{:NV12}) and no scaling
  defp maybe_plug_swscale_converter_vulkan(
         builder,
         input_format,
         %H264{width: nil, height: nil},
         _suffix
       )
       when is_vk_video_friendly_format(input_format),
       do: builder

  defp maybe_plug_swscale_converter_vulkan(
         builder,
         _input_format,
         %H264{} = output_format,
         suffix
       ) do
    builder
    |> child(child_name(suffix, :raw_video_converter), swscale_converter(:NV12, output_format))
  end

  # H264 (VK decoded to NV12) → H265 (FFmpeg encoder needs I420): always convert
  defp maybe_plug_swscale_converter_vulkan(builder, %H264{}, %H265{} = output_format, suffix) do
    builder
    |> child(child_name(suffix, :raw_video_converter), swscale_converter(:I420, output_format))
  end

  defp maybe_plug_swscale_converter_vulkan(builder, input_format, output_format, suffix),
    do: maybe_plug_swscale_converter(builder, input_format, output_format, suffix)

  # RawVideo → RawVideo: skip when no scaling and no pixel format change
  defp maybe_plug_swscale_converter(
         builder,
         input_format,
         %RawVideo{pixel_format: out_pf, width: nil, height: nil},
         _suffix
       )
       when raw_video_passthrough(input_format, out_pf),
       do: builder

  defp maybe_plug_swscale_converter(
         builder,
         input_format,
         %RawVideo{pixel_format: pixel_format} = output_format,
         suffix
       ) do
    format = pixel_format || raw_pixel_format(input_format)

    builder
    |> child(child_name(suffix, :raw_video_converter), swscale_converter(format, output_format))
  end

  # → H264/H265: skip when input is already compatible and no scaling
  defp maybe_plug_swscale_converter(
         builder,
         input_format,
         %h26x{width: nil, height: nil},
         _suffix
       )
       when h26x in [H264, H265] and is_x264_friendly_format(input_format),
       do: builder

  defp maybe_plug_swscale_converter(builder, _input_format, %h26x{} = output_format, suffix)
       when h26x in [H264, H265] do
    builder
    |> child(child_name(suffix, :raw_video_converter), swscale_converter(:I420, output_format))
  end

  # Catch-all: scale to I420 if resolution requested, otherwise passthrough
  defp maybe_plug_swscale_converter(
         builder,
         _input_format,
         %{width: w, height: h} = output_format,
         suffix
       )
       when not is_nil(w) and not is_nil(h) do
    builder
    |> child(child_name(suffix, :raw_video_converter), swscale_converter(:I420, output_format))
  end

  defp maybe_plug_swscale_converter(builder, _input_format, _output_format, _suffix), do: builder

  defp swscale_converter(format, %{width: w, height: h}) when not is_nil(w) and not is_nil(h),
    do: %SWScale.Converter{format: format, output_width: w, output_height: h}

  defp swscale_converter(format, _output_format), do: %SWScale.Converter{format: format}

  defp raw_pixel_format(%RawVideo{pixel_format: pixel_format}), do: pixel_format || :I420
  defp raw_pixel_format(_encoded_format), do: :I420

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

  defp plug_h264_input_parser(builder, suffix),
    do:
      child(builder, child_name(suffix, :h264_input_parser), %H264.Parser{
        output_stream_structure: :annexb,
        output_alignment: :au
      })

  defp plug_output_parser(builder, %H264{} = h264, suffix) do
    # VKVideo.Transcoder outputs annexb/au, so we need a parser if the output format differs
    output_structure = stream_structure_type(h264)
    output_alignment = h264.alignment

    # Only add parser if stream structure or alignment needs to be changed
    if output_structure != :annexb or output_alignment != :au do
      builder
      |> child(child_name(suffix, :h264_output_parser), %H264.Parser{
        output_stream_structure: output_structure,
        output_alignment: output_alignment
      })
    else
      builder
    end
  end

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
       virtual_buffer_size_ms: Membrane.Time.as_milliseconds(virtual_buffer_size, :round)
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
       virtual_buffer_size_ms: Membrane.Time.as_milliseconds(virtual_buffer_size, :round)
     }}
  end

  defp get_h264_ffmpeg_params(nil), do: %{}

  defp get_h264_ffmpeg_params(%ConstantBitrate{bitrate: bitrate, virtual_buffer_size: vbr_ns}) do
    vbr_ms = Membrane.Time.as_milliseconds(vbr_ns, :round)

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
    vbr_ms = Membrane.Time.as_milliseconds(vbr_ns, :round)

    %{
      "b" => Integer.to_string(avg),
      "maxrate" => Integer.to_string(max),
      "bufsize" => Integer.to_string(trunc(max * vbr_ms / 1000))
    }
  end

  defp get_h265_x265_params(nil), do: ""

  defp get_h265_x265_params(%ConstantBitrate{bitrate: bitrate, virtual_buffer_size: vbr_ns}) do
    vbr_ms = Membrane.Time.as_milliseconds(vbr_ns, :round)

    "bitrate=#{bitrate}:vbv-bufsize=#{trunc(bitrate * vbr_ms / 1000.0 / 8)}:vbv-maxrate=#{bitrate}"
  end

  defp get_h265_x265_params(%VariableBitrate{
         average_bitrate: avg,
         max_bitrate: max,
         virtual_buffer_size: vbr_ns
       }) do
    vbr_ms = Membrane.Time.as_milliseconds(vbr_ns, :round)
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
