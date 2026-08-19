defmodule Membrane.Transcoder.Audio do
  @moduledoc false

  import Membrane.ChildrenSpec
  alias Membrane.{ChildrenSpec, RemoteStream, Transcoder}
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

  @aac_channels 1..8

  @opus_channels 1..2

  @type input_format ::
          Membrane.AAC.t()
          | Membrane.Opus.t()
          | Membrane.MPEGAudio.t()
          | Membrane.RawAudio.t()
          | %RemoteStream{content_format: Membrane.AAC | Membrane.MPEGAudio}
          | %RemoteStream{content_format: Membrane.Opus, type: :packetized}

  @type output_format ::
          OutputFormat.AAC.t()
          | OutputFormat.Opus.t()
          | OutputFormat.MPEGAudio.t()
          | OutputFormat.RawAudio.t()

  @typep accepted_raw_formats_spec :: %{
           sample_format: [Membrane.RawAudio.SampleFormat.t()] | :any,
           sample_rate: [Membrane.RawAudio.sample_rate_t()] | :any,
           channels: [Membrane.RawAudio.channels_t()] | :any
         }

  @aac_encoder_accepted_raw_formats_spec %{
    sample_format: [:s16le],
    sample_rate: [
      44_100,
      96_000,
      88_200,
      64_000,
      48_000,
      32_000,
      24_000,
      22_050,
      16_000,
      12_000,
      11_025,
      8000
    ],
    channels: 1..8 |> Enum.to_list()
  }

  @opus_encoder_accepted_raw_formats_spec %{
    sample_format: [:s16le],
    sample_rate: [48_000],
    channels: [2, 1]
  }

  @mp3_encoder_accepted_raw_formats_spec %{
    sample_format: [:s32le],
    sample_rate: [44_100],
    channels: [2]
  }

  defguardp is_raw_audio(format)
            when is_struct(format) and
                   format.__struct__ in [Membrane.RawAudio, OutputFormat.RawAudio]

  defguardp is_aac(format)
            when is_struct(format) and
                   (format.__struct__ in [Membrane.AAC, OutputFormat.AAC] or
                      (format.__struct__ == RemoteStream and
                         format.content_format == Membrane.AAC))

  defguardp is_opus(format)
            when is_struct(format) and
                   (format.__struct__ in [Membrane.Opus, OutputFormat.Opus] or
                      (format.__struct__ == RemoteStream and
                         format.content_format == Membrane.Opus and
                         format.type == :packetized))

  defguardp is_mpeg_audio(format)
            when is_struct(format) and
                   (format.__struct__ in [Membrane.MPEGAudio, OutputFormat.MPEGAudio] or
                      (format.__struct__ == RemoteStream and
                         format.content_format == Membrane.MPEGAudio))

  defguard is_audio_format(format)
           when is_raw_audio(format) or
                  is_aac(format) or
                  is_opus(format) or
                  is_mpeg_audio(format)

  defguard is_opus_compliant(format)
           when is_map_key(format, :sample_format) and format.sample_format == :s16le and
                  is_map_key(format, :sample_rate) and format.sample_rate == 48_000 and
                  is_map_key(format, :channels) and format.channels in @opus_channels

  defguard is_aac_compliant(format)
           when is_map_key(format, :sample_format) and format.sample_format == :s16le and
                  is_map_key(format, :sample_rate) and format.sample_rate in @aac_sample_rates and
                  is_map_key(format, :channels) and format.channels in @aac_channels

  defguard is_mp3_compliant(format)
           when is_map_key(format, :sample_rate) and format.sample_rate == 44_100 and
                  is_map_key(format, :sample_format) and format.sample_format == :s32le and
                  is_map_key(format, :channels) and format.channels == 2

  @spec plug_audio_transcoding(
          ChildrenSpec.builder(),
          input_format(),
          output_format(),
          Transcoder.transcoding_policy(),
          Transcoder.State.OutputSpec.t()
        ) :: ChildrenSpec.builder()
  def plug_audio_transcoding(
        builder,
        input_format,
        output_format,
        transcoding_policy,
        output_spec
      )
      when is_audio_format(input_format) and is_audio_format(output_format) do
    if should_be_transcoded(input_format, output_format, transcoding_policy) do
      if transcoding_policy == :never do
        raise """
        Cannot convert input format #{inspect(input_format)} to output format #{inspect(output_format)} \
        with :transcoding_policy option set to :never.
        """
      end

      plug_transcoding(builder, input_format, output_format, output_spec)
    else
      plug_non_transcoding_conversion(builder, input_format, output_format, output_spec)
    end
  end

  @spec should_be_transcoded(input_format(), output_format(), Transcoder.transcoding_policy()) ::
          boolean()
  defp should_be_transcoded(input_format, output_format, transcoding_policy) do
    transcoding_policy == :always or
      not are_same_formats(input_format, output_format) or
      (input_format.__struct__ == Membrane.RawAudio and
         output_format.__struct__ == OutputFormat.RawAudio)
  end

  @spec are_same_formats(input_format(), output_format()) :: boolean()
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
          input_format(),
          output_format(),
          Transcoder.State.OutputSpec.t()
        ) :: ChildrenSpec.builder()
  defp plug_non_transcoding_conversion(builder, input_format, output_format, output_spec) do
    suffix = output_spec.suffix

    case {input_format, output_format} do
      {input_format, %OutputFormat.AAC{}} when is_aac(input_format) ->
        builder |> child({:aac_input_parser, suffix}, Membrane.AAC.Parser)

      {input_format, %OutputFormat.Opus{}} when is_opus(input_format) ->
        builder
        |> child({:opus_parser, suffix}, %Membrane.Opus.Parser{
          delimitation: if(output_format.self_delimiting?, do: :delimit, else: :undelimit)
        })

      _other ->
        builder
    end
  end

  @spec plug_transcoding(
          ChildrenSpec.builder(),
          input_format(),
          output_format(),
          Transcoder.State.OutputSpec.t()
        ) :: ChildrenSpec.builder()
  defp plug_transcoding(builder, input_format, output_format, output_spec) do
    {raw_audio_producing_segment, produced_audio_formats} =
      get_raw_audio_producing_segment(input_format, output_spec)

    {raw_audio_consuming_segment, consumed_audio_formats} =
      get_raw_audio_consuming_segment(output_format, output_spec)

    raw_audio_resampling_segment =
      get_raw_audio_resampling_segment(
        produced_audio_formats,
        consumed_audio_formats,
        output_spec
      )

    builder
    |> then(raw_audio_producing_segment)
    |> then(raw_audio_resampling_segment)
    |> then(raw_audio_consuming_segment)
  end

  @spec get_raw_audio_producing_segment(
          input_format(),
          Transcoder.State.OutputSpec.t()
        ) :: {(ChildrenSpec.builder() -> ChildrenSpec.builder()), accepted_raw_formats_spec()}
  defp get_raw_audio_producing_segment(input_format, output_spec) do
    suffix = output_spec.suffix

    case input_format do
      %Membrane.RawAudio{} ->
        {& &1, get_accepted_raw_formats_spec_from_format(input_format)}

      input_format when is_aac(input_format) ->
        pipeline_segment =
          &(&1
            |> child({:aac_input_parser, suffix}, Membrane.AAC.Parser)
            |> child({:aac_decoder, suffix}, Membrane.AAC.FDK.Decoder))

        accepted_raw_formats_spec = %{
          sample_format: [:s16le],
          sample_rate:
            case input_format do
              %Membrane.AAC{sample_rate: sample_rate} when not is_nil(sample_rate) ->
                [sample_rate]

              _sample_rate_unknown ->
                :any
            end,
          channels:
            case input_format do
              %Membrane.AAC{channels: channels} when not is_nil(channels) -> [channels]
              _sample_rate_unknown -> :any
            end
        }

        {pipeline_segment, accepted_raw_formats_spec}

      input_format when is_opus(input_format) ->
        pipeline_segment =
          &(&1
            |> child({:opus_input_parser, suffix}, %Membrane.Opus.Parser{
              delimitation: :undelimit
            })
            |> child({:opus_decoder, suffix}, Membrane.Opus.Decoder))

        {pipeline_segment, get_accepted_raw_formats_spec_from_format(input_format)}

      input_format when is_mpeg_audio(input_format) ->
        pipeline_segment =
          &(&1
            |> child({:mp3_decoder, suffix}, Membrane.MP3.MAD.Decoder))

        {pipeline_segment, get_accepted_raw_formats_spec_from_format(input_format)}
    end
  end

  @spec get_accepted_raw_formats_spec_from_format(input_format() | output_format()) ::
          accepted_raw_formats_spec()
  defp get_accepted_raw_formats_spec_from_format(format) do
    [:sample_format, :sample_rate, :channels]
    |> Map.new(fn key ->
      value =
        case Map.get(format, key, :any) do
          :any -> :any
          value -> [value]
        end

      {key, value}
    end)
  end

  # @spec get_accepted_raw_formats_spec_from_format(input_format() | output_format(), atom()) ::
  #         [Membrane]
  # defp get_accepted_raw_formats_spec_from_format(format, field) do
  #   case Map.get(format, field, :any) do
  #   end
  # end

  @spec get_raw_audio_consuming_segment(
          output_format(),
          Transcoder.State.OutputSpec.t()
        ) :: {(ChildrenSpec.builder() -> ChildrenSpec.builder()), accepted_raw_formats_spec()}
  defp get_raw_audio_consuming_segment(output_format, output_spec) do
    suffix = output_spec.suffix

    case output_format do
      %OutputFormat.RawAudio{} ->
        {& &1, get_accepted_raw_formats_spec_from_format(output_format)}

      %OutputFormat.AAC{} ->
        pipeline_segment =
          &(&1
            |> child({:aac_encoder, suffix}, Membrane.AAC.FDK.Encoder)
            |> child({:aac_output_parser, suffix}, %Membrane.AAC.Parser{
              output_config: output_format.config,
              out_encapsulation: output_format.encapsulation
            }))

        {pipeline_segment, @aac_encoder_accepted_raw_formats_spec}

      %OutputFormat.Opus{} ->
        pipeline_segment =
          &(&1
            |> child({:opus_encoder, suffix}, Membrane.Opus.Encoder)
            |> child({:opus_output_parser, suffix}, %Membrane.Opus.Parser{
              delimitation: if(output_format.self_delimiting?, do: :delimit, else: :undelimit)
            }))

        {pipeline_segment, @opus_encoder_accepted_raw_formats_spec}

      %OutputFormat.MPEGAudio{} ->
        pipeline_segment =
          &(&1 |> child({:mp3_encoder, suffix}, Membrane.MP3.Lame.Encoder))

        {pipeline_segment, @mp3_encoder_accepted_raw_formats_spec}
    end
  end

  @spec get_raw_audio_resampling_segment(
          accepted_raw_formats_spec(),
          accepted_raw_formats_spec(),
          Transcoder.State.OutputSpec.t()
        ) :: (ChildrenSpec.builder() -> ChildrenSpec.builder())
  defp get_raw_audio_resampling_segment(
         produced_audio_formats,
         consumed_audio_formats,
         output_spec
       ) do
    resampler_output_format =
      [:sample_format, :sample_rate, :channels]
      |> Map.new(fn field ->
        consumed_audio_field_values = Map.get(consumed_audio_formats, field)
        produced_audio_field_values = Map.get(produced_audio_formats, field)

        produced_field_values_consumable? =
          cond do
            consumed_audio_field_values == :any ->
              true

            produced_audio_field_values == :any ->
              false

            true ->
              MapSet.new(produced_audio_field_values)
              |> MapSet.subset?(MapSet.new(consumed_audio_field_values))
          end

        if produced_field_values_consumable? do
          {field, :keep}
        else
          {field, List.first(consumed_audio_field_values)}
        end
      end)

    if resampler_output_format == %{sample_format: :keep, sample_rate: :keep, channels: :keep} do
      & &1
    else
      &(&1
        |> child({:resampler, output_spec.suffix}, %Membrane.FFmpeg.SWResample.Converter{
          output_stream_format:
            struct!(Membrane.FFmpeg.SWResample.Converter.OutputFormat, resampler_output_format)
        }))
    end
  end
end
