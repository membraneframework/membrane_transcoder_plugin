defmodule Membrane.Transcoder.Video.VariableBitrate do
  @moduledoc """
  Defines encoder setting for variable bitrate rate control algorithm.

  The following fields need to be specified:
  * average_bitrate - Target average bitrate for VBR encoding; the encoder will try to meet this
    average over the sequence; expressed in bits per second.
  * max_bitrate - Maximum allowed bitrate in VBR encoding; caps peak bitrate to prevent excessive
    spikes while maintaining average bitrate constraints; expressed in bits per second.
  * virtual_buffer_size - virtual buffer duration for rate control smoothing; larger values
    increase bitrate stability, smaller values improve responsiveness to scene changes;
    expressed in nanoseconds as `Membrane.Time.t()`, defaults to 2 seconds.
  """

  @type t :: %__MODULE__{
          average_bitrate: non_neg_integer(),
          max_bitrate: non_neg_integer(),
          virtual_buffer_size: Membrane.Time.t()
        }
  @enforce_keys [:average_bitrate, :max_bitrate]
  defstruct @enforce_keys ++ [virtual_buffer_size: Membrane.Time.seconds(2)]
end
