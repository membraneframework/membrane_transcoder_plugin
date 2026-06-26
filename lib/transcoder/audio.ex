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

  defguardp is_raw_audio_format(format)
            when is_struct(format) and format.__struct__ == RawAudio

  defguardp is_aac_format(format)
            when is_struct(format) and format.__struct__ == AAC

  defguardp is_opus_format(format)
            when is_struct(format) and
                   (format.__struct__ == Opus or
                      (format.__struct__ == RemoteStream and
                         format.content_format == Opus and
                         format.type == :packetized))

  defguardp is_mpeg_audio_format(format)
            when is_struct(format) and
                   (format.__struct__ == MPEGAudio or
                      (format.__struct__ == RemoteStream and
                         format.content_format == MPEGAudio))

  defguard is_audio_format(format)
           when is_raw_audio_format(format) or
                  is_aac_format(format) or
                  is_opus_format(format) or
                  is_mpeg_audio_format(format)

  defguard is_opus_compliant(format)
           when is_map_key(format, :content_type) and format.content_type == :s16le and
                  is_map_key(format, :sample_rate) and format.sample_rate == 48_000

  defguard is_aac_compliant(format)
           when is_map_key(format, :content_type) and format.content_type == :s16le and
                  is_map_key(format, :sample_rate) and format.sample_rate in @aac_sample_rates

  defguard is_mp3_compliant(format)
           when is_map_key(format, :sample_rate) and format.sample_rate == 44_100 and
                  is_map_key(format, :sample_format) and format.sample_format == :s32le and
                  is_map_key(format, :channels) and format.channels == 2

  @spec plug_audio_transcoding(
          ChildrenSpec.builder(),
          audio_stream_format() | RemoteStream.t(),
          audio_stream_format(),
          :always | :if_needed | :never,
          map()
        ) :: ChildrenSpec.builder()
  def plug_audio_transcoding(
        builder,
        input_format,
        output_format,
        transcoding_policy,
        output_spec
      )
      when is_audio_format(input_format) and is_audio_format(output_format) do
    do_plug_audio_transcoding(
      builder,
      input_format,
      output_format,
      transcoding_policy,
      output_spec.suffix
    )
  end

  defp do_plug_audio_transcoding(
         builder,
         %format_module{},
         %format_module{},
         transcoding_policy,
         _suffix
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
         transcoding_policy,
         suffix
       )
       when transcoding_policy in [:if_needed, :never] do
    builder |> child(child_name(suffix, :opus_parser), Opus.Parser)
  end

  defp do_plug_audio_transcoding(_builder, input_format, output_format, :never, _suffix) do
    raise """
    Cannot convert input format #{inspect(input_format)} to output format #{inspect(output_format)} \
    with :transcoding_policy option set to :never.
    """
  end

  defp do_plug_audio_transcoding(
         builder,
         input_format,
         output_format,
         _transcoding_policy,
         suffix
       ) do
    builder
    |> maybe_plug_input_parser(input_format, suffix)
    |> maybe_plug_decoder(input_format, suffix)
    |> maybe_plug_resampler(input_format, output_format, suffix)
    |> maybe_plug_encoder(output_format, suffix)
    |> maybe_plug_output_parser(output_format, suffix)
  end

  defp maybe_plug_input_parser(builder, %AAC{}, suffix) do
    builder |> child(child_name(suffix, :aac_input_parser), AAC.Parser)
  end

  defp maybe_plug_input_parser(builder, _input_format, _suffix) do
    builder
  end

  defp maybe_plug_decoder(builder, %Opus{}, suffix) do
    builder |> child(child_name(suffix, :opus_decoder), Opus.Decoder)
  end

  defp maybe_plug_decoder(builder, %RemoteStream{content_format: Opus, type: :packetized}, suffix) do
    builder |> child(child_name(suffix, :opus_decoder), Opus.Decoder)
  end

  defp maybe_plug_decoder(builder, %AAC{}, suffix) do
    builder |> child(child_name(suffix, :aac_decoder), AAC.FDK.Decoder)
  end

  defp maybe_plug_decoder(builder, %MPEGAudio{}, suffix) do
    builder |> child(child_name(suffix, :mp3_decoder), Membrane.MP3.MAD.Decoder)
  end

  defp maybe_plug_decoder(builder, %RemoteStream{content_format: MPEGAudio}, suffix) do
    builder |> child(child_name(suffix, :mp3_decoder), Membrane.MP3.MAD.Decoder)
  end

  defp maybe_plug_decoder(builder, %RawAudio{}, _suffix) do
    builder
  end

  defp maybe_plug_resampler(builder, input_format, %Opus{}, suffix)
       when not is_opus_compliant(input_format) do
    builder
    |> child(child_name(suffix, :resampler), %Membrane.FFmpeg.SWResample.Converter{
      output_stream_format: %RawAudio{
        sample_format: :s16le,
        sample_rate: 48_000,
        channels: 1
      }
    })
  end

  defp maybe_plug_resampler(builder, input_format, %AAC{}, suffix)
       when not is_aac_compliant(input_format) do
    builder
    |> child(child_name(suffix, :resampler), %Membrane.FFmpeg.SWResample.Converter{
      output_stream_format: %RawAudio{
        sample_format: :s16le,
        sample_rate: 44_100,
        channels: 1
      }
    })
  end

  defp maybe_plug_resampler(builder, input_format, %MPEGAudio{}, suffix)
       when not is_mp3_compliant(input_format) do
    builder
    |> child(child_name(suffix, :resampler), %Membrane.FFmpeg.SWResample.Converter{
      output_stream_format: %RawAudio{sample_rate: 44_100, sample_format: :s32le, channels: 2}
    })
  end

  defp maybe_plug_resampler(builder, _input_format, _output_format, _suffix) do
    builder
  end

  defp maybe_plug_encoder(builder, %Opus{}, suffix) do
    builder |> child(child_name(suffix, :opus_encoder), Opus.Encoder)
  end

  defp maybe_plug_encoder(builder, %AAC{}, suffix) do
    builder |> child(child_name(suffix, :aac_encoder), AAC.FDK.Encoder)
  end

  defp maybe_plug_encoder(builder, %MPEGAudio{}, suffix) do
    builder |> child(child_name(suffix, :mp3_encoder), Membrane.MP3.Lame.Encoder)
  end

  defp maybe_plug_encoder(builder, %RawAudio{}, _suffix) do
    builder
  end

  defp maybe_plug_output_parser(builder, %Opus{} = output_format, suffix) do
    delimitation = if output_format.self_delimiting?, do: :undelimit, else: :delimit

    builder
    |> child(child_name(suffix, :opus_output_parser), %Membrane.Opus.Parser{
      delimitation: delimitation
    })
  end

  defp maybe_plug_output_parser(builder, %AAC{} = output_format, suffix) do
    builder
    |> child(child_name(suffix, :aac_output_parser), %Membrane.AAC.Parser{
      output_config: output_format.config,
      out_encapsulation: output_format.encapsulation,
      samples_per_frame: output_format.samples_per_frame
    })
  end

  defp maybe_plug_output_parser(builder, _output_format, _suffix) do
    builder
  end

  defp child_name(nil, base), do: base
  defp child_name(suffix, base), do: {base, suffix}
end
