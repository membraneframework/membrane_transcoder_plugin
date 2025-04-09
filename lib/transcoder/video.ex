defmodule Membrane.Transcoder.Video do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Logger
  alias Membrane.{ChildrenSpec, H264, H265, RawVideo, RemoteStream, VP8}

  @type video_stream_format :: VP8.t() | H264.t() | H265.t() | RawVideo.t()

  defguard is_video_format(format)
           when is_struct(format) and
                  (format.__struct__ in [VP8, H264, H265, RawVideo] or
                     (format.__struct__ == RemoteStream and format.content_format == VP8 and
                        format.type == :packetized))

  @spec plug_video_transcoding(
          ChildrenSpec.builder(),
          video_stream_format(),
          video_stream_format(),
          boolean()
        ) :: ChildrenSpec.builder()
  def plug_video_transcoding(builder, input_format, output_format, transcoding_policy)
      when is_video_format(input_format) and is_video_format(output_format) do
    do_plug_video_transcoding(builder, input_format, output_format, transcoding_policy)
  end

  defp do_plug_video_transcoding(
         builder,
         %h26x{},
         %h26x{} = output_format,
         transcoding_policy
       )
       when h26x in [H264, H265] and transcoding_policy in [:if_needed, :never] do
    parser =
      h26x
      |> Module.concat(Parser)
      |> struct!(
        output_stream_structure: stream_structure_type(output_format),
        output_alignment: output_format.alignment
      )

    builder |> child(:h264_parser, parser)
  end

  defp do_plug_video_transcoding(
         builder,
         %format_module{},
         %format_module{},
         transcoding_policy
       )
       when transcoding_policy in [:if_needed, :never] do
    Membrane.Logger.debug("""
    This bin will only forward buffers, as the input stream format is the same type as the output stream format.
    """)

    builder
  end

  defp do_plug_video_transcoding(_builder, input_format, output_format, :never) do
    raise """
    Cannot convert input format #{inspect(input_format)} to output format #{inspect(output_format)} \
    with :transcoding_policy option set to :never.
    """
  end

  defp do_plug_video_transcoding(builder, input_format, output_format, _transcoding_policy) do
    builder
    |> maybe_plug_parser_and_decoder(input_format)
    |> maybe_plug_encoder_and_parser(output_format)
  end

  defp maybe_plug_parser_and_decoder(builder, %H264{}) do
    builder
    |> child(:h264_input_parser, %H264.Parser{
      output_stream_structure: :annexb,
      output_alignment: :au
    })
    |> child(:h264_decoder, %H264.FFmpeg.Decoder{})
  end

  defp maybe_plug_parser_and_decoder(builder, %H265{}) do
    builder
    |> child(:h265_input_parser, %H265.Parser{
      output_stream_structure: :annexb,
      output_alignment: :au
    })
    |> child(:h265_decoder, %H265.FFmpeg.Decoder{})
  end

  defp maybe_plug_parser_and_decoder(builder, %VP8{}) do
    builder |> child(:vp8_decoder, %VP8.Decoder{})
  end

  defp maybe_plug_parser_and_decoder(builder, %RemoteStream{
         content_format: VP8,
         type: :packetized
       }) do
    builder |> child(:vp8_decoder, %VP8.Decoder{})
  end

  defp maybe_plug_parser_and_decoder(builder, %RawVideo{}) do
    builder
  end

  defp maybe_plug_encoder_and_parser(builder, %H264{} = h264) do
    builder
    |> child(:h264_encoder, %H264.FFmpeg.Encoder{preset: :ultrafast})
    |> child(:h264_output_parser, %H264.Parser{
      output_stream_structure: stream_structure_type(h264),
      output_alignment: h264.alignment
    })
  end

  defp maybe_plug_encoder_and_parser(builder, %H265{} = h265) do
    builder
    |> child(:h265_encoder, %H265.FFmpeg.Encoder{preset: :ultrafast})
    |> child(:h265_output_parser, %H265.Parser{
      output_stream_structure: stream_structure_type(h265),
      output_alignment: h265.alignment
    })
  end

  defp maybe_plug_encoder_and_parser(builder, %VP8{}) do
    cpu_quota = :erlang.system_info(:cpu_quota)

    number_of_threads =
      if cpu_quota != :unknown,
        do: cpu_quota,
        else: :erlang.system_info(:logical_processors_available)

    builder |> child(:vp8_encoder, %VP8.Encoder{g_threads: number_of_threads, cpu_used: 15})
  end

  defp maybe_plug_encoder_and_parser(builder, %RawVideo{}) do
    builder
  end

  defp stream_structure_type(%h26x{stream_structure: stream_structure})
       when h26x in [H264, H265] do
    case stream_structure do
      type when type in [:annexb, :avc1, :avc3, :hvc1, :hev1] -> type
      {type, _dcr} when type in [:avc1, :avc3, :hvc1, :hev1] -> type
    end
  end
end
