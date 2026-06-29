defmodule Membrane.Transcoder.Audio do
  @moduledoc false

  import Membrane.ChildrenSpec
  alias Membrane.{ChildrenSpec, RemoteStream}
  alias Membrane.Transcoder.OutputFormat

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

  @type audio_input_format ::
          Membrane.AAC.t() | Membrane.Opus.t() | Membrane.MPEGAudio.t() | Membrane.RawAudio.t()

  @type audio_output_format ::
          OutputFormat.AAC.t()
          | OutputFormat.Opus.t()
          | OutputFormat.MPEGAudio.t()
          | OutputFormat.RawAudio.t()

  defguardp is_raw_audio_format(format)
            when is_struct(format) and
                   format.__struct__ in [Membrane.RawAudio, OutputFormat.RawAudio]

  defguardp is_aac_format(format)
            when is_struct(format) and
                   (format.__struct__ in [Membrane.AAC, OutputFormat.AAC] or
                      (format.__struct__ == RemoteStream and
                         format.content_format == Membrane.AAC))

  defguardp is_opus_format(format)
            when is_struct(format) and
                   (format.__struct__ in [Membrane.Opus, OutputFormat.Opus] or
                      (format.__struct__ == RemoteStream and
                         format.content_format == Membrane.Opus))

  defguardp is_mpeg_audio_format(format)
            when is_struct(format) and
                   (format.__struct__ in [Membrane.MPEGAudio, OutputFormat.MPEGAudio] or
                      (format.__struct__ == RemoteStream and
                         format.content_format == Membrane.MPEGAudio))

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
          audio_input_format() | Membrane.RemoteStream.t(),
          audio_output_format(),
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

  defp do_plug_audio_transcoding(builder, input_format, output_format, transcoding_policy, suffix)
       when transcoding_policy in [:if_needed, :never] and is_opus_format(input_format) and
              is_opus_format(output_format) do
    builder
    |> child(child_name(suffix, :opus_parser), %Membrane.Opus.Parser{
      delimitation: get_opus_delimitation(output_format)
    })
  end

  defp do_plug_audio_transcoding(builder, input_format, output_format, transcoding_policy, suffix)
       when transcoding_policy in [:if_needed, :never] and is_aac_format(input_format) and
              is_aac_format(output_format) do
    builder
    |> child(child_name(suffix, :aac_parser), %Membrane.AAC.Parser{
      output_config: output_format.config,
      samples_per_frame: output_format.samples_per_frame,
      out_encapsulation: output_format.encapsulation
    })
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

  defp maybe_plug_input_parser(builder, %Membrane.AAC{}, suffix) do
    builder |> child(child_name(suffix, :aac_input_parser), Membrane.AAC.Parser)
  end

  defp maybe_plug_input_parser(builder, _input_format, _suffix) do
    builder
  end

  defp maybe_plug_decoder(builder, %Membrane.Opus{}, suffix) do
    builder |> child(child_name(suffix, :opus_decoder), Membrane.Opus.Decoder)
  end

  defp maybe_plug_decoder(
         builder,
         %RemoteStream{content_format: Membrane.Opus, type: :packetized},
         suffix
       ) do
    builder |> child(child_name(suffix, :opus_decoder), Membrane.Opus.Decoder)
  end

  defp maybe_plug_decoder(builder, %Membrane.AAC{}, suffix) do
    builder |> child(child_name(suffix, :aac_decoder), Membrane.AAC.FDK.Decoder)
  end

  defp maybe_plug_decoder(builder, %Membrane.MPEGAudio{}, suffix) do
    builder |> child(child_name(suffix, :mp3_decoder), Membrane.MP3.MAD.Decoder)
  end

  defp maybe_plug_decoder(builder, %RemoteStream{content_format: Membrane.MPEGAudio}, suffix) do
    builder |> child(child_name(suffix, :mp3_decoder), Membrane.MP3.MAD.Decoder)
  end

  defp maybe_plug_decoder(builder, %Membrane.RawAudio{}, _suffix) do
    builder
  end

  defp maybe_plug_resampler(builder, input_format, %OutputFormat.Opus{}, suffix)
       when not is_opus_compliant(input_format) do
    builder
    |> child(child_name(suffix, :resampler), %Membrane.FFmpeg.SWResample.Converter{
      output_stream_format: %Membrane.RawAudio{
        sample_format: :s16le,
        sample_rate: 48_000,
        channels: 1
      }
    })
  end

  defp maybe_plug_resampler(builder, input_format, %OutputFormat.AAC{}, suffix)
       when not is_aac_compliant(input_format) do
    builder
    |> child(child_name(suffix, :resampler), %Membrane.FFmpeg.SWResample.Converter{
      output_stream_format: %Membrane.RawAudio{
        sample_format: :s16le,
        sample_rate: 44_100,
        channels: 1
      }
    })
  end

  defp maybe_plug_resampler(builder, input_format, %OutputFormat.MPEGAudio{}, suffix)
       when not is_mp3_compliant(input_format) do
    builder
    |> child(child_name(suffix, :resampler), %Membrane.FFmpeg.SWResample.Converter{
      output_stream_format: %Membrane.RawAudio{
        sample_rate: 44_100,
        sample_format: :s32le,
        channels: 2
      }
    })
  end

  defp maybe_plug_resampler(builder, _input_format, _output_format, _suffix) do
    builder
  end

  defp maybe_plug_encoder(builder, %OutputFormat.Opus{}, suffix) do
    builder |> child(child_name(suffix, :opus_encoder), Membrane.Opus.Encoder)
  end

  defp maybe_plug_encoder(builder, %OutputFormat.AAC{}, suffix) do
    builder |> child(child_name(suffix, :aac_encoder), Membrane.AAC.FDK.Encoder)
  end

  defp maybe_plug_encoder(builder, %OutputFormat.MPEGAudio{}, suffix) do
    builder |> child(child_name(suffix, :mp3_encoder), Membrane.MP3.Lame.Encoder)
  end

  defp maybe_plug_encoder(builder, %OutputFormat.RawAudio{}, _suffix) do
    builder
  end

  defp maybe_plug_output_parser(builder, %OutputFormat.Opus{} = output_format, suffix) do
    delimitation = if output_format.self_delimiting?, do: :undelimit, else: :delimit

    builder
    |> child(child_name(suffix, :opus_output_parser), %Membrane.Opus.Parser{
      delimitation: delimitation
    })
  end

  defp maybe_plug_output_parser(builder, %OutputFormat.AAC{} = output_format, suffix) do
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

  @spec get_opus_delimitation(OutputFormat.Opus.t()) :: Membrane.Opus.Parser.delimitation_t()
  defp get_opus_delimitation(output_format) do
    if output_format.self_delimiting?, do: :undelimit, else: :delimit
  end

  defp child_name(nil, base), do: base
  defp child_name(suffix, base), do: {base, suffix}
end
