defmodule Membrane.Transcoder.OutputFormat do
  @moduledoc """
  Structs for defining the desired output stream formats. When an output format is specified with a
  struct from this module then a matching stream format will be produced. For example, specifying
  output format as `%Membrane.Transcoder.OutputFormat.H264{stream_structure: :annexb, alignment: :au}`
  will result in the Transcoder producing a stream with stream format `Membrane.H264`, which will
  have `:stream_structure` field set to `:annexb`, and `:alignment` to `:au`.
  """

  alias __MODULE__.{AAC, H264, H265, MPEGAudio, Opus, RawAudio, RawVideo, VP8, VP9}

  @type t ::
          H264.t()
          | H265.t()
          | VP8.t()
          | VP9.t()
          | RawVideo.t()
          | AAC.t()
          | Opus.t()
          | MPEGAudio.t()
          | RawAudio.t()
          | H264
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

    @typedoc """
    If a field is set to `:any` then the Transcoder will be free to choose any valid value
    for the output stream and the subsequent component must be able to handle it.
    """
    @type t :: %__MODULE__{
            alignment: :au | :nalu,
            stream_structure:
              :annexb | :avc1 | :avc3 | {:avc1 | :avc3, nalu_length_size :: pos_integer()},
            width: Membrane.H264.width() | :any,
            height: Membrane.H264.width() | :any
          }

    defstruct alignment: :au, stream_structure: :annexb, width: :any, height: :any
  end

  defmodule H265 do
    @moduledoc """
    Struct defining the desired output H265 stream format.
    """

    @typedoc """
    If a field is set to `:any` then the Transcoder will be free to choose any valid value
    for the output stream and the subsequent component must be able to handle it.
    """
    @type t :: %__MODULE__{
            alignment: :au | :nalu,
            stream_structure:
              :annexb | :hev1 | :hvc1 | {:hev1 | :hvc1, nalu_length_size :: pos_integer()},
            width: Membrane.H264.width() | :any,
            height: Membrane.H264.width() | :any
          }

    defstruct alignment: :au, stream_structure: :annexb, width: :any, height: :any
  end

  defmodule VP8 do
    @moduledoc """
    Struct defining the desired output VP8 stream format.
    """

    @typedoc """
    If a field is set to `:any` then the Transcoder will be free to choose any valid value
    for the output stream and the subsequent component must be able to handle it.
    """
    @type t :: %__MODULE__{
            width: Membrane.VP8.width() | :any,
            height: Membrane.VP8.width() | :any
          }

    defstruct width: :any, height: :any
  end

  defmodule VP9 do
    @moduledoc """
    Struct defining the desired output VP9 stream format.
    """

    @typedoc """
    If a field is set to `:any` then the Transcoder will be free to choose any valid value
    for the output stream and the subsequent component must be able to handle it.
    """
    @type t :: %__MODULE__{
            width: Membrane.VP9.width() | :any,
            height: Membrane.VP9.width() | :any
          }

    defstruct width: :any, height: :any
  end

  defmodule RawVideo do
    @moduledoc """
    Struct defining the desired output RawVideo stream format.
    """

    @typedoc """
    If a field is set to `:any` then the Transcoder will be free to choose any valid value
    for the output stream and the subsequent component must be able to handle it.
    """
    @type t :: %__MODULE__{
            pixel_format: Membrane.RawVideo.pixel_format() | :any,
            width: Membrane.RawVideo.width() | :any,
            height: Membrane.RawVideo.width() | :any
          }
    defstruct pixel_format: :any, width: :any, height: :any
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
            encapsulation: Membrane.AAC.encapsulation(),
            samples_per_frame: Membrane.AAC.samples_per_frame()
          }
    defstruct config: nil,
              encapsulation: :none,
              samples_per_frame: 1024
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
    Struct defining the desired output Membrane stream format.
    """

    @type t :: %__MODULE__{}
    defstruct []
  end

  defmodule RawAudio do
    @moduledoc """
    Struct defining the desired output RawAudio stream format.
    """

    @type t :: %__MODULE__{
            sample_format: Membrane.RawAudio.SampleFormat.t(),
            sample_rate: Membrane.RawAudio.sample_rate_t(),
            channels: Membrane.RawAudio.channels_t()
          }
    defstruct sample_format: :s16le,
              sample_rate: 48_000,
              channels: 1
  end
end
