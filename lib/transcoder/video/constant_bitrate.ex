defmodule Membrane.Transcoder.Video.ConstantBitrate do
  @moduledoc """
  Defines encoder setting for constant bitrate rate control algorithm.

  The following fields need to be specified:
  * bitrate - desired bitrate of the stream; expressed in bits per second.
  * virtual_buffer_size - virtual buffer duration for rate control smoothing;
    larger values increase bitrate stability, smaller values improve responsiveness
    to scene changes; expressed as `Membrane.Time.t()`, defaults to 2 seconds.
  """

  @type t :: %__MODULE__{bitrate: non_neg_integer(), virtual_buffer_size: Membrane.Time.t()}
  @enforce_keys [:bitrate]
  defstruct @enforce_keys ++ [virtual_buffer_size: Membrane.Time.seconds(2)]
end
