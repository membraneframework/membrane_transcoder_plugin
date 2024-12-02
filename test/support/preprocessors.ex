defmodule Membrane.Transcoder.Support.Preprocessors do
  import Membrane.ChildrenSpec

  def decode_h264(link_builder) do
    child(link_builder, %Membrane.H264.Parser{
      output_alignment: :au,
      output_stream_structure: :annexb,
      generate_best_effort_timestamps: %{framerate: {30, 1}}
    })
    |> child(%Membrane.H264.FFmpeg.Decoder{})
  end

  def parse_h264(link_builder) do
    child(link_builder, %Membrane.H264.Parser{
      output_alignment: :au,
      output_stream_structure: :annexb,
      generate_best_effort_timestamps: %{framerate: {30, 1}}
    })
  end

  def parse_h265(link_builder) do
    child(link_builder, %Membrane.H265.Parser{
      output_alignment: :au,
      output_stream_structure: :annexb,
      generate_best_effort_timestamps: %{framerate: {30, 1}}
    })
  end

  def parse_vp8(link_builder) do
    child(link_builder, Membrane.IVF.Deserializer)
  end

  def parse_raw_audio(link_builder, stream_format) do
    child(link_builder, %Membrane.RawAudioParser{
      stream_format: stream_format,
      overwrite_pts?: true
    })
  end

  def parse_aac(link_builder) do
    child(link_builder, %Membrane.AAC.Parser{out_encapsulation: :ADTS})
  end

  def parse_opus(link_builder) do
    child(link_builder, %Membrane.Opus.Parser{
      input_delimitted?: true,
      delimitation: :undelimit,
      generate_best_effort_timestamps?: true
    })
  end
end
