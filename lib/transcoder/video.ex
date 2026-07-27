defmodule Membrane.Transcoder.Video do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad
  alias Membrane.{ChildrenSpec, Pad, RemoteStream, Transcoder}
  alias Membrane.FFmpeg.SWScale
  alias Membrane.Transcoder.OutputFormat
  alias Membrane.Transcoder.Video.{ConstantBitrate, VariableBitrate}

  @type input_format ::
          Membrane.VP8.t()
          | Membrane.VP9.t()
          | Membrane.H264.t()
          | Membrane.H265.t()
          | Membrane.RawVideo.t()
          | %RemoteStream{content_format: Membrane.VP8 | Membrane.VP9, type: :packetized}
          | %RemoteStream{content_format: Membrane.H264 | Membrane.H265}

  @type output_format ::
          OutputFormat.VP8.t()
          | OutputFormat.VP9.t()
          | OutputFormat.H264.t()
          | OutputFormat.H265.t()
          | OutputFormat.RawVideo.t()

  defguardp is_h264(format)
            when format.__struct__ in [Membrane.H264, OutputFormat.H264] or
                   (format.__struct__ == RemoteStream and format.content_format == Membrane.H264)

  defguardp is_h265(format)
            when format.__struct__ in [Membrane.H265, OutputFormat.H265] or
                   (format.__struct__ == RemoteStream and format.content_format == Membrane.H265)

  defguardp is_vp8(format)
            when format.__struct__ in [Membrane.VP8, OutputFormat.VP8] or
                   (format.__struct__ == RemoteStream and format.content_format == Membrane.VP8 and
                      format.type == :packetized)

  defguardp is_vp9(format)
            when format.__struct__ in [Membrane.VP9, OutputFormat.VP9] or
                   (format.__struct__ == RemoteStream and format.content_format == Membrane.VP9 and
                      format.type == :packetized)

  defguardp is_raw_video(format)
            when is_struct(format) and
                   format.__struct__ in [Membrane.RawVideo, OutputFormat.RawVideo]

  defguard is_video_format(format)
           when is_h264(format) or
                  is_h265(format) or
                  is_vp8(format) or
                  is_vp9(format) or
                  is_raw_video(format)

  @vpx_pixel_formats [:I420, :I422, :I444, :NV12, :YV12]
  @x264_x265_pixel_formats [:I420, :I422]
  @vkvideo_pixel_formats [:NV12]

  @spec plug_video_transcoding(
          ChildrenSpec.builder(),
          Transcoder.video_input_format(),
          output_format(),
          Transcoder.transcoding_policy(),
          boolean(),
          Transcoder.State.OutputSpec.t()
        ) :: ChildrenSpec.builder()
  def plug_video_transcoding(
        builder,
        input_format,
        output_format,
        transcoding_policy,
        use_vk_video?,
        output_spec
      ) do
    if should_be_transcoded(input_format, output_format, transcoding_policy, output_spec) do
      if transcoding_policy == :never do
        raise """
        Cannot convert input format #{inspect(input_format)} to output format #{inspect(output_format)}
        with bitrate `#{inspect(output_spec.bitrate)}` and resolution `#{inspect(output_spec.resolution)}`
        when `:transcoding_policy` option is set to `:never`.
        """
      end

      maybe_plug_single_element_transcoding(
        builder,
        input_format,
        output_format,
        use_vk_video?,
        output_spec
      ) ||
        plug_multi_element_transcoding(
          builder,
          input_format,
          output_format,
          use_vk_video?,
          output_spec
        )
    else
      plug_non_transcoding_conversion(builder, input_format, output_format, output_spec)
    end
  end

  @spec should_be_transcoded(
          Transcoder.video_input_format(),
          output_format(),
          Transcoder.transcoding_policy(),
          Transcoder.State.OutputSpec.t()
        ) :: boolean()
  defp should_be_transcoded(input_format, output_format, transcoding_policy, output_spec) do
    transcoding_policy == :always or
      output_spec.resolution != :keep or
      output_spec.bitrate != :default or
      not are_same_formats(input_format, output_format)
  end

  @spec are_same_formats(Transcoder.video_input_format(), output_format()) :: boolean()
  defp are_same_formats(input_format, output_format) do
    input_format_suffix =
      case input_format do
        %RemoteStream{content_format: format} -> format
        stream_format -> stream_format.__struct__
      end
      |> Module.split()
      |> List.last()

    output_format_suffix = output_format.__struct__ |> Module.split() |> List.last()

    input_format_suffix == output_format_suffix
  end

  @spec plug_non_transcoding_conversion(
          ChildrenSpec.builder(),
          Transcoder.video_input_format(),
          output_format(),
          Transcoder.State.OutputSpec.t()
        ) :: ChildrenSpec.builder()
  defp plug_non_transcoding_conversion(builder, input_format, output_format, output_spec) do
    case {input_format, output_format} do
      {input_format, %OutputFormat.H264{}} when is_h264(input_format) ->
        builder
        |> child({:h264_parser, output_spec.suffix}, %Membrane.H264.Parser{
          output_stream_structure: output_format.stream_structure,
          output_alignment: output_format.alignment
        })

      {input_format, %OutputFormat.H265{}} when is_h265(input_format) ->
        builder
        |> child({:h265_parser, output_spec.suffix}, %Membrane.H265.Parser{
          output_stream_structure: output_format.stream_structure,
          output_alignment: output_format.alignment
        })

      {%Membrane.RawVideo{pixel_format: input_pixel_format},
       %OutputFormat.RawVideo{pixel_format: output_pixel_format}} ->
        builder
        |> then(
          get_raw_video_converting_segment(
            [input_pixel_format],
            if(output_pixel_format == :any, do: :any, else: [output_pixel_format]),
            output_spec
          )
        )

      _other ->
        builder
    end
  end

  @spec maybe_plug_single_element_transcoding(
          ChildrenSpec.builder(),
          Transcoder.video_input_format(),
          output_format(),
          boolean(),
          Transcoder.State.OutputSpec.t()
        ) :: ChildrenSpec.builder() | nil
  defp maybe_plug_single_element_transcoding(
         builder,
         input_format,
         output_format,
         use_vk_video?,
         %Transcoder.State.OutputSpec{resolution: resolution} = output_spec
       ) do
    case {input_format, output_format} do
      {%Membrane.H264{width: width, height: height}, %OutputFormat.H264{}}
      when use_vk_video? and resolution == :keep and not is_nil(width) and not is_nil(height) ->
        resolution = %{width: width, height: height}
        plug_vulkan_transcoder(builder, output_format, resolution, output_spec)

      {input_format, %OutputFormat.H264{}}
      when is_h264(input_format) and use_vk_video? and resolution != :keep ->
        plug_vulkan_transcoder(builder, output_format, output_spec.resolution, output_spec)

      _other ->
        nil
    end
  end

  @spec plug_vulkan_transcoder(
          ChildrenSpec.builder(),
          output_format(),
          Transcoder.resolution(),
          Transcoder.State.OutputSpec.t()
        ) :: ChildrenSpec.builder()
  defp plug_vulkan_transcoder(builder, output_format, resolution, output_spec) do
    builder =
      builder
      |> child({:h264_input_parser, output_spec.suffix}, %Membrane.H264.Parser{
        output_stream_structure: :annexb,
        output_alignment: :au
      })
      |> child({:vk_transcoder, output_spec.suffix}, Membrane.VKVideo.Transcoder)
      |> via_out(Pad.ref(:output, 0),
        options: [
          width: resolution.width,
          height: resolution.height,
          scaling_algorithm: :bilinear,
          rate_control: get_vkvideo_rate_control(output_spec.bitrate)
        ]
      )

    if output_format.stream_structure != :annexb or output_format.alignment != :au do
      builder
      |> child({:h264_output_parser, output_spec.suffix}, %Membrane.H264.Parser{
        output_stream_structure: output_format.stream_structure,
        output_alignment: output_format.alignment
      })
    else
      builder
    end
  end

  @spec plug_multi_element_transcoding(
          ChildrenSpec.builder(),
          Transcoder.video_input_format(),
          output_format(),
          boolean(),
          Transcoder.State.OutputSpec.t()
        ) :: ChildrenSpec.builder()
  defp plug_multi_element_transcoding(
         builder,
         input_format,
         output_format,
         use_vk_video?,
         output_spec
       ) do
    {raw_video_producing_segment, produced_pixel_formats} =
      get_raw_video_producing_segment(input_format, use_vk_video?, output_spec)

    {raw_video_consuming_segment, consumed_pixel_formats} =
      get_raw_video_consuming_segment(output_format, use_vk_video?, output_spec)

    raw_video_converting_segment =
      get_raw_video_converting_segment(
        produced_pixel_formats,
        consumed_pixel_formats,
        output_spec
      )

    builder
    |> then(raw_video_producing_segment)
    |> then(raw_video_converting_segment)
    |> then(raw_video_consuming_segment)
  end

  @spec get_raw_video_producing_segment(
          Transcoder.video_input_format(),
          boolean(),
          Transcoder.State.OutputSpec.t()
        ) ::
          {(ChildrenSpec.builder() -> ChildrenSpec.builder()), [Membrane.RawVideo.pixel_format()]}
  defp get_raw_video_producing_segment(input_format, use_vk_video?, output_spec) do
    suffix = output_spec.suffix

    case input_format do
      %Membrane.RawVideo{pixel_format: pixel_format} ->
        {& &1, [pixel_format]}

      input_format when is_vp8(input_format) ->
        pipeline_segment =
          &(&1
            |> child({:vp8_decoder, suffix}, Membrane.VP8.Decoder))

        {pipeline_segment, @vpx_pixel_formats}

      input_format when is_vp9(input_format) ->
        pipeline_segment =
          &(&1
            |> child({:vp9_decoder, suffix}, Membrane.VP9.Decoder))

        {pipeline_segment, @vpx_pixel_formats}

      input_format when is_h264(input_format) and use_vk_video? ->
        pipeline_segment =
          &(&1
            |> child({:h264_input_parser, suffix}, %Membrane.H264.Parser{
              output_stream_structure: :annexb,
              output_alignment: :au
            })
            |> child({:vk_h264_decoder, suffix}, Membrane.VKVideo.Decoder))

        {pipeline_segment, @vkvideo_pixel_formats}

      input_format when is_h264(input_format) and not use_vk_video? ->
        pipeline_segment =
          &(&1
            |> child({:h264_input_parser, suffix}, %Membrane.H264.Parser{
              output_stream_structure: :annexb,
              output_alignment: :au
            })
            |> child({:h264_decoder, suffix}, Membrane.H264.FFmpeg.Decoder))

        {pipeline_segment, @x264_x265_pixel_formats}

      input_format when is_h265(input_format) ->
        pipeline_segment =
          &(&1
            |> child({:h265_input_parser, suffix}, %Membrane.H265.Parser{
              output_stream_structure: :annexb,
              output_alignment: :au
            })
            |> child({:h265_decoder, suffix}, Membrane.H265.FFmpeg.Decoder))

        {pipeline_segment, @x264_x265_pixel_formats}
    end
  end

  @spec get_raw_video_consuming_segment(
          output_format(),
          boolean(),
          Transcoder.State.OutputSpec.t()
        ) ::
          {(ChildrenSpec.builder() -> ChildrenSpec.builder()),
           [Membrane.RawVideo.pixel_format()] | :any}
  defp get_raw_video_consuming_segment(output_format, use_vk_video?, output_spec) do
    suffix = output_spec.suffix

    case output_format do
      %OutputFormat.RawVideo{pixel_format: :any} ->
        {& &1, :any}

      %OutputFormat.RawVideo{pixel_format: pixel_format} ->
        {& &1, [pixel_format]}

      %OutputFormat.VP8{} ->
        pipeline_segment =
          &(&1
            |> child({:vp8_encoder, suffix}, %Membrane.VP8.Encoder{
              g_threads: cpu_count(),
              cpu_used: 15,
              rc_target_bitrate: get_vpx_target_bitrate(output_spec.bitrate)
            }))

        {pipeline_segment, @vpx_pixel_formats}

      %OutputFormat.VP9{} ->
        pipeline_segment =
          &(&1
            |> child({:vp9_encoder, suffix}, %Membrane.VP9.Encoder{
              g_threads: cpu_count(),
              cpu_used: 15,
              rc_target_bitrate: get_vpx_target_bitrate(output_spec.bitrate)
            }))

        {pipeline_segment, @vpx_pixel_formats}

      %OutputFormat.H264{} when use_vk_video? ->
        pipeline_segment =
          &(&1
            |> child(
              {:vk_h264_encoder, suffix},
              struct!(Membrane.VKVideo.Encoder,
                rate_control: get_vkvideo_rate_control(output_spec.bitrate)
              )
            )
            |> maybe_plug_post_encoding_h264_parser(output_format, suffix))

        {pipeline_segment, @vkvideo_pixel_formats}

      %OutputFormat.H264{} when not use_vk_video? ->
        encoder =
          if output_spec.bitrate == :default do
            %Membrane.H264.FFmpeg.Encoder{preset: :ultrafast}
          else
            %Membrane.H264.FFmpeg.Encoder{
              preset: :ultrafast,
              ffmpeg_params: get_h264_ffmpeg_params(output_spec.bitrate),
              crf: -1
            }
          end

        pipeline_segment =
          &(&1
            |> child({:h264_encoder, suffix}, encoder)
            |> maybe_plug_post_encoding_h264_parser(output_format, suffix))

        {pipeline_segment, @x264_x265_pixel_formats}

      %OutputFormat.H265{} ->
        pipeline_segment =
          &(&1
            |> child({:h265_encoder, suffix}, %Membrane.H265.FFmpeg.Encoder{
              preset: :ultrafast,
              x265_params: get_h265_x265_params(output_spec.bitrate)
            })
            |> maybe_plug_post_encoding_h265_parser(output_format, suffix))

        {pipeline_segment, @x264_x265_pixel_formats}
    end
  end

  @spec get_raw_video_converting_segment(
          [Membrane.RawVideo.pixel_format()],
          [Membrane.RawVideo.pixel_format()] | :any,
          Transcoder.State.OutputSpec.t()
        ) :: (ChildrenSpec.builder() -> ChildrenSpec.builder())
  defp get_raw_video_converting_segment(
         produced_pixel_formats,
         consumed_pixel_formats,
         output_spec
       ) do
    produced_pixel_formats_consumable? =
      if consumed_pixel_formats == :any do
        true
      else
        MapSet.new(produced_pixel_formats)
        |> MapSet.subset?(MapSet.new(consumed_pixel_formats))
      end

    converter_pixel_format =
      if produced_pixel_formats_consumable? do
        nil
      else
        List.first(consumed_pixel_formats)
      end

    {converter_width, converter_height} =
      case output_spec.resolution do
        :keep -> {nil, nil}
        %{width: width, height: height} -> {width, height}
      end

    if converter_pixel_format == nil and converter_width == nil and converter_height == nil do
      & &1
    else
      &(&1
        |> child({:raw_video_converter, output_spec.suffix}, %SWScale.Converter{
          format: converter_pixel_format,
          output_width: converter_width,
          output_height: converter_height
        }))
    end
  end

  @spec maybe_plug_post_encoding_h264_parser(
          ChildrenSpec.builder(),
          OutputFormat.H264.t(),
          term()
        ) :: ChildrenSpec.builder()
  defp maybe_plug_post_encoding_h264_parser(builder, output_format, suffix) do
    if output_format.alignment != :au or output_format.stream_structure != :annexb do
      builder
      |> child({:h264_output_parser, suffix}, %Membrane.H264.Parser{
        output_alignment: output_format.alignment,
        output_stream_structure: output_format.stream_structure
      })
    else
      builder
    end
  end

  @spec maybe_plug_post_encoding_h265_parser(
          ChildrenSpec.builder(),
          OutputFormat.H265.t(),
          term()
        ) :: ChildrenSpec.builder()
  defp maybe_plug_post_encoding_h265_parser(builder, output_format, suffix) do
    if output_format.alignment != :au or output_format.stream_structure != :annexb do
      builder
      |> child({:h265_output_parser, suffix}, %Membrane.H265.Parser{
        output_alignment: output_format.alignment,
        output_stream_structure: output_format.stream_structure
      })
    else
      builder
    end
  end

  @spec get_vkvideo_rate_control(Transcoder.bitrate_option() | :default) :: term()
  defp get_vkvideo_rate_control(:default), do: :encoder_default

  defp get_vkvideo_rate_control(%ConstantBitrate{
         bitrate: bitrate,
         virtual_buffer_size: virtual_buffer_size
       }) do
    {:constant_bitrate,
     struct!(Membrane.VKVideo.Encoder.ConstantBitrate,
       bitrate: bitrate,
       virtual_buffer_size_ms: Membrane.Time.as_milliseconds(virtual_buffer_size, :round)
     )}
  end

  defp get_vkvideo_rate_control(%VariableBitrate{
         average_bitrate: avg,
         max_bitrate: max,
         virtual_buffer_size: virtual_buffer_size
       }) do
    {:variable_bitrate,
     struct!(Membrane.VKVideo.Encoder.VariableBitrate,
       average_bitrate: avg,
       max_bitrate: max,
       virtual_buffer_size_ms: Membrane.Time.as_milliseconds(virtual_buffer_size, :round)
     )}
  end

  @spec get_h264_ffmpeg_params(Transcoder.bitrate_option()) :: %{String.t() => String.t()}
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

  @spec get_h265_x265_params(Transcoder.bitrate_option() | :default) :: String.t()
  defp get_h265_x265_params(:default), do: ""

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

  @spec get_vpx_target_bitrate(Transcoder.bitrate_option() | :default) :: pos_integer() | :auto
  defp get_vpx_target_bitrate(:default), do: :auto

  defp get_vpx_target_bitrate(%ConstantBitrate{bitrate: bitrate}), do: trunc(bitrate / 1000)

  defp get_vpx_target_bitrate(%VariableBitrate{average_bitrate: avg}), do: trunc(avg / 1000)

  @spec cpu_count() :: pos_integer()
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
end
