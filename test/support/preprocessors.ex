defmodule Membrane.Transcoder.Support.Preprocessors do
  @moduledoc false
  import Membrane.ChildrenSpec

  @raw_audio_stream_format %Membrane.RawAudio{
    channels: 2,
    sample_rate: 44_100,
    sample_format: :s16le
  }

  @spec decode_h264(Membrane.ChildrenSpec.builder()) :: Membrane.ChildrenSpec.builder()
  def decode_h264(link_builder) do
    child(link_builder, %Membrane.H264.Parser{
      output_alignment: :au,
      output_stream_structure: :annexb,
      generate_best_effort_timestamps: %{framerate: {30, 1}}
    })
    |> child(%Membrane.H264.FFmpeg.Decoder{})
  end

  @spec parse_h264(Membrane.ChildrenSpec.builder()) :: Membrane.ChildrenSpec.builder()
  def parse_h264(link_builder) do
    link_builder
    |> child(%Membrane.H264.Parser{
      output_alignment: :au,
      output_stream_structure: :annexb,
      generate_best_effort_timestamps: %{framerate: {30, 1}}
    })
  end

  @spec parse_h265(Membrane.ChildrenSpec.builder()) :: Membrane.ChildrenSpec.builder()
  def parse_h265(link_builder) do
    child(link_builder, %Membrane.H265.Parser{
      output_alignment: :au,
      output_stream_structure: :annexb,
      generate_best_effort_timestamps: %{framerate: {30, 1}}
    })
  end

  @spec parse_vp8(Membrane.ChildrenSpec.builder()) :: Membrane.ChildrenSpec.builder()
  def parse_vp8(link_builder) do
    child(link_builder, Membrane.IVF.Deserializer)
  end

  @spec parse_raw_audio(Membrane.ChildrenSpec.builder()) :: Membrane.ChildrenSpec.builder()
  def parse_raw_audio(link_builder) do
    child(link_builder, %Membrane.RawAudioParser{
      stream_format: @raw_audio_stream_format,
      overwrite_pts?: true
    })
  end

  @spec parse_aac(Membrane.ChildrenSpec.builder()) :: Membrane.ChildrenSpec.builder()
  def parse_aac(link_builder) do
    child(link_builder, %Membrane.AAC.Parser{out_encapsulation: :ADTS})
  end

  @spec parse_opus(Membrane.ChildrenSpec.builder()) :: Membrane.ChildrenSpec.builder()
  def parse_opus(link_builder) do
    child(link_builder, %Membrane.Opus.Parser{
      input_delimitted?: true,
      delimitation: :undelimit,
      generate_best_effort_timestamps?: true
    })
  end
end
