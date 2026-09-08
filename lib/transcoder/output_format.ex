defmodule Membrane.Transcoder.OutputFormat do
  @moduledoc """
  Structs for defining the desired output stream formats. When an output format is specified with a
  struct from this module then a matching stream format will be produced. For example, specifying
  output format as `%Membrane.Transcoder.OutputFormat.H264{stream_structure: :annexb, alignment: :au}`
  will result in the Transcoder producing a stream with stream format `Membrane.H264`, which will
  have `:stream_structure` field set to `:annexb`, and `:alignment` to `:au`.
  """

  alias Membrane.Transcoder
  alias __MODULE__.{AAC, H264, H265, MPEGAudio, Opus, RawAudio, RawVideo, VP8, VP9}

  @type video ::
          VP8.t()
          | VP9.t()
          | H264.t()
          | H265.t()
          | RawVideo.t()

  @type audio ::
          AAC.t()
          | Opus.t()
          | MPEGAudio.t()
          | RawAudio.t()

  @type t :: audio() | video()

  @type mod ::
          H264
          | H265
          | VP8
          | VP9
          | RawVideo
          | AAC
          | Opus
          | MPEGAudio
          | RawAudio

  defmodule H264 do
    @moduledoc """
    Struct defining the desired output H264 stream format.
    """
    @type t :: %__MODULE__{
            alignment: :au | :nalu,
            stream_structure:
              :annexb | :avc1 | :avc3 | {:avc1 | :avc3, nalu_length_size :: pos_integer()}
          }

    defstruct alignment: :au, stream_structure: :annexb
  end

  defmodule H265 do
    @moduledoc """
    Struct defining the desired output H265 stream format.
    """
    @type t :: %__MODULE__{
            alignment: :au | :nalu,
            stream_structure:
              :annexb | :hev1 | :hvc1 | {:hev1 | :hvc1, nalu_length_size :: pos_integer()}
          }

    defstruct alignment: :au, stream_structure: :annexb
  end

  defmodule VP8 do
    @moduledoc """
    Struct defining the desired output VP8 stream format.
    """
    @type t :: %__MODULE__{}

    defstruct []
  end

  defmodule VP9 do
    @moduledoc """
    Struct defining the desired output VP9 stream format.
    """
    @type t :: %__MODULE__{}

    defstruct []
  end

  defmodule RawVideo do
    @moduledoc """
    Struct defining the desired output RawVideo stream format.
    """

    @typedoc """
    If `:pixel_format` is set to `:any` then the Transcoder will be free to choose any pixel format
    for the output stream and the subsequent component must be able to handle it.
    """
    @type t :: %__MODULE__{pixel_format: Membrane.RawVideo.pixel_format() | :any}
    defstruct pixel_format: :any
  end

  defmodule AAC do
    @moduledoc """
    Struct defining the desired output AAC stream format.
    """

    @type t :: %__MODULE__{
            config:
              :audio_specific_config
              | :esds
              | {:esds, avg_bit_rate :: non_neg_integer(), max_bit_rate :: non_neg_integer()}
              | nil,
            encapsulation: Membrane.AAC.encapsulation()
          }
    defstruct config: nil,
              encapsulation: :none
  end

  defmodule Opus do
    @moduledoc """
    Struct defining the desired output Opus stream format.
    """

    @type t :: %__MODULE__{self_delimiting?: boolean()}
    defstruct self_delimiting?: false
  end

  defmodule MPEGAudio do
    @moduledoc """
    Struct defining the desired output MPEGAudio stream format.
    """

    @type t :: %__MODULE__{}
    defstruct []
  end

  defmodule RawAudio do
    @moduledoc """
    Struct defining the desired output RawAudio stream format.
    """

    @type t :: %__MODULE__{
            sample_format: Membrane.RawAudio.SampleFormat.t() | :any,
            sample_rate: Membrane.RawAudio.sample_rate_t() | :any,
            channels: Membrane.RawAudio.channels_t() | :any
          }
    defstruct sample_format: :any,
              sample_rate: :any,
              channels: :any
  end

  @accepted_input_format_modules [
    Membrane.H264,
    Membrane.H265,
    Membrane.VP8,
    Membrane.VP9,
    Membrane.RawVideo,
    Membrane.AAC,
    Membrane.Opus,
    Membrane.MPEGAudio,
    Membrane.RawAudio
  ]

  @spec from_input_format(Transcoder.input_format()) :: t()
  def from_input_format(%Membrane.H264{alignment: alignment, stream_structure: :annexb}) do
    %H264{alignment: alignment, stream_structure: :annexb}
  end

  def from_input_format(%Membrane.H264{alignment: alignment, stream_structure: {avc, _dcr}}) do
    %H264{alignment: alignment, stream_structure: avc}
  end

  def from_input_format(%Membrane.H265{alignment: alignment, stream_structure: :annexb}) do
    %H265{alignment: alignment, stream_structure: :annexb}
  end

  def from_input_format(%Membrane.H265{alignment: alignment, stream_structure: {hevc, _dcr}}) do
    %H265{alignment: alignment, stream_structure: hevc}
  end

  def from_input_format(%Membrane.RawVideo{pixel_format: pixel_format}) do
    %RawVideo{pixel_format: pixel_format}
  end

  def from_input_format(%Membrane.AAC{
        encapsulation: encapsulation,
        config: {config_type, _content}
      }) do
    %AAC{encapsulation: encapsulation, config: config_type}
  end

  def from_input_format(%Membrane.AAC{encapsulation: encapsulation, config: nil}) do
    %AAC{encapsulation: encapsulation, config: nil}
  end

  def from_input_format(%Membrane.Opus{self_delimiting?: self_delimiting?}) do
    %Opus{self_delimiting?: self_delimiting?}
  end

  def from_input_format(%Membrane.RawAudio{
        sample_format: sample_format,
        sample_rate: sample_rate,
        channels: channels
      }) do
    %RawAudio{
      sample_format: sample_format,
      sample_rate: sample_rate,
      channels: channels
    }
  end

  def from_input_format(%Membrane.RemoteStream{content_format: format})
      when format in @accepted_input_format_modules do
    format
    |> Module.split()
    |> List.last()
    |> String.to_existing_atom()
    |> then(&Module.concat(__MODULE__, &1))
    |> struct!()
  end

  def from_input_format(other_format)
      when is_struct(other_format) and
             other_format.__struct__ in @accepted_input_format_modules do
    other_format.__struct__
    |> Module.split()
    |> List.last()
    |> String.to_existing_atom()
    |> then(&Module.concat(__MODULE__, &1))
    |> struct!()
  end
end
