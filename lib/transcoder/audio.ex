defmodule Membrane.Transcoder.Audio do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Logger
  alias Membrane.{AAC, ChildrenSpec, MPEGAudio, Opus, RawAudio, RemoteStream}

  @aac_sample_rates [
    96_000,
    88_200,
    64_000,
    48_000,
    44_100,
    32_000,
    24_000,
    22_050,
    16_000,
    12_000,
    11_025,
    8000
  ]

  @type audio_stream_format :: AAC.t() | Opus.t() | Membrane.MPEGAudio.t() | RawAudio.t()

  defguard is_audio_format(format)
           when is_struct(format) and
                  (format.__struct__ in [AAC, Opus, MPEGAudio, RawAudio] or
                     (format.__struct__ == RemoteStream and
                        format.content_format == Opus and
                        format.type == :packetized) or
                     (format.__struct__ == RemoteStream and format.content_format == MPEGAudio))

  defguard is_opus_compliant(format)
           when is_map_key(format, :content_type) and format.content_type == :s16le and
                  is_map_key(format, :sample_rate) and format.sample_rate == 48_000

  defguard is_aac_compliant(format)
           when is_map_key(format, :content_type) and format.content_type == :s16le and
                  is_map_key(format, :sample_rate) and format.sample_rate in @aac_sample_rates

  defguard is_mp3_compliant(format)
           when is_map_key(format, :sample_rate) and format.sample_rate == 44_100 and
                  is_map_key(format, :sample_format) and format.sample_format == :s32le and
                  is_map_key(
                    format,
                    :channels
                  ) and format.channels == 2

  @spec plug_audio_transcoding(
          ChildrenSpec.builder(),
          audio_stream_format() | RemoteStream.t(),
          audio_stream_format(),
          boolean()
        ) :: ChildrenSpec.builder()
  def plug_audio_transcoding(builder, input_format, output_format, transcoding_policy)
      when is_audio_format(input_format) and is_audio_format(output_format) do
    do_plug_audio_transcoding(builder, input_format, output_format, transcoding_policy)
  end

  defp do_plug_audio_transcoding(
         builder,
         %format_module{},
         %format_module{},
         transcoding_policy
       )
       when transcoding_policy in [:if_needed, :never] do
    Membrane.Logger.debug("""
    This bin will only forward buffers, as the input stream format is the same as the output stream format.
    """)

    builder
  end

  defp do_plug_audio_transcoding(
         builder,
         %RemoteStream{content_format: Opus},
         %Opus{},
         transcoding_policy
       )
       when transcoding_policy in [:if_needed, :never] do
    builder |> child(:opus_parser, Opus.Parser)
  end

  defp do_plug_audio_transcoding(_builder, input_format, output_format, :never) do
    raise """
    Cannot convert input format #{inspect(input_format)} to output format #{inspect(output_format)} \
    with :transcoding_policy option set to :never.
    """
  end

  defp do_plug_audio_transcoding(builder, input_format, output_format, _transcoding_policy) do
    builder
    |> maybe_plug_parser(input_format)
    |> maybe_plug_decoder(input_format)
    |> maybe_plug_resampler(input_format, output_format)
    |> maybe_plug_encoder(output_format)
  end

  defp maybe_plug_parser(builder, %AAC{}) do
    builder |> child(:aac_parser, AAC.Parser)
  end

  defp maybe_plug_parser(builder, _input_format) do
    builder
  end

  defp maybe_plug_decoder(builder, %Opus{}) do
    builder |> child(:opus_decoder, Opus.Decoder)
  end

  defp maybe_plug_decoder(builder, %RemoteStream{content_format: Opus, type: :packetized}) do
    builder |> child(:opus_decoder, Opus.Decoder)
  end

  defp maybe_plug_decoder(builder, %AAC{}) do
    builder |> child(:aac_decoder, AAC.FDK.Decoder)
  end

  defp maybe_plug_decoder(builder, %MPEGAudio{}) do
    builder |> child(:mp3_decoder, Membrane.MP3.MAD.Decoder)
  end

  defp maybe_plug_decoder(builder, %RemoteStream{content_format: MPEGAudio}) do
    builder |> child(:mp3_decoder, Membrane.MP3.MAD.Decoder)
  end

  defp maybe_plug_decoder(builder, %RawAudio{}) do
    builder
  end

  defp maybe_plug_resampler(builder, input_format, %Opus{})
       when not is_opus_compliant(input_format) do
    builder
    |> child(:resampler, %Membrane.FFmpeg.SWResample.Converter{
      output_stream_format: %RawAudio{
        sample_format: :s16le,
        sample_rate: 48_000,
        channels: 1
      }
    })
  end

  defp maybe_plug_resampler(builder, input_format, %AAC{})
       when not is_aac_compliant(input_format) do
    builder
    |> child(:resampler, %Membrane.FFmpeg.SWResample.Converter{
      output_stream_format: %RawAudio{
        sample_format: :s16le,
        sample_rate: 44_100,
        channels: 1
      }
    })
  end

  defp maybe_plug_resampler(builder, input_format, %MPEGAudio{})
       when not is_mp3_compliant(input_format) do
    builder
    |> child(:resampler, %Membrane.FFmpeg.SWResample.Converter{
      output_stream_format: %RawAudio{sample_rate: 44_100, sample_format: :s32le, channels: 2}
    })
  end

  defp maybe_plug_resampler(builder, _input_format, _output_format) do
    builder
  end

  defp maybe_plug_encoder(builder, %Opus{}) do
    builder |> child(:opus_encoder, Opus.Encoder)
  end

  defp maybe_plug_encoder(builder, %AAC{}) do
    builder |> child(:aac_encoder, AAC.FDK.Encoder)
  end

  defp maybe_plug_encoder(builder, %MPEGAudio{}) do
    builder |> child(:mp3_encoder, Membrane.MP3.Lame.Encoder)
  end

  defp maybe_plug_encoder(builder, %RawAudio{}) do
    builder
  end
end
