defmodule Membrane.Transcoder do
  @moduledoc """
  Provides transcoding capabilities for audio and video streams in Membrane.

  The bin takes an incoming stream on its input and converts it into the desired one
  as specified by the option. Transcoding is applied only if it is neccessary.
  The following video stream formats are supported:
  * `Membrane.H264`
  * `Membrane.H265`
  * `Membrane.VP8`
  * `Membrane.RawVideo`

  The following audio stream formats are supported:
  * `Membrane.AAC`
  * `Membrane.Opus`
  * `Membrane.RawAudio`
  * `Membrane.RemoteStream{content_type: Membrane.Opus}` (only as input stream)

  Please note that not all the conversions are possible!
  """
  use Membrane.Bin

  require __MODULE__.Audio
  require __MODULE__.Video
  require Membrane.Logger

  alias __MODULE__.{Audio, ForwardingFilter, Video}
  alias Membrane.{AAC, Funnel, H264, H265, Opus, RawAudio, RawVideo, RemoteStream, VP8}

  @typedoc """
  Describes stream formats acceptable on the bin's input and output.
  """
  @type stream_format ::
          H264.t()
          | H265.t()
          | VP8.t()
          | RawVideo.t()
          | AAC.t()
          | Opus.t()
          | RemoteStream.t()
          | RawAudio.t()

  @typedoc """
  Describes stream format modules that can be used to define inputs and outputs of the bin.
  """
  @type stream_format_module :: H264 | H265 | VP8 | RawVideo | AAC | Opus | RawAudio

  @typedoc """
  Describes a function which can be used to provide output format based on the input format.
  """
  @type stream_format_resolver :: (stream_format() -> stream_format() | stream_format_module())

  def_input_pad :input,
    accepted_format: format when Audio.is_audio_format(format) or Video.is_video_format(format)

  def_output_pad :output,
    accepted_format: format when Audio.is_audio_format(format) or Video.is_video_format(format)

  def_options output_stream_format: [
                spec: stream_format() | stream_format_module() | stream_format_resolver(),
                description: """
                An option specifying desired output format.
                Can be either:
                * a struct being a Membrane stream format,
                * a module in which Membrane stream format struct is defined,
                * a function which receives input stream format as an input argument
                and is supposed to return the desired output stream format or its module.
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    spec = [
      bin_input()
      |> child(:forwarding_filter, ForwardingFilter),
      child(:output_funnel, Funnel)
      |> bin_output()
    ]

    state =
      opts
      |> Map.from_struct()
      |> Map.put(:input_stream_format, nil)

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(
        {:stream_format, format},
        :forwarding_filter,
        _ctx,
        %{input_stream_format: nil} = state
      ) do
    state =
      %{state | input_stream_format: format}
      |> resolve_output_stream_format()

    spec =
      get_child(:forwarding_filter)
      |> plug_transcoding(format, state.output_stream_format)
      |> get_child(:output_funnel)

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(
        {:stream_format, new_format},
        :forwarding_filter,
        _ctx,
        %{input_stream_format: non_nil_stream_format} = state
      ) do
    if new_format != non_nil_stream_format do
      raise """
      Received new stream format on transcoder's input: #{inspect(new_format)}
      which doesn't match the first received input stream format: #{inspect(non_nil_stream_format)}
      Transcoder doesn't support updating the input stream format.
      """
    end

    {[], state}
  end

  @impl true
  def handle_child_notification(_notification, _element, _ctx, state) do
    {[], state}
  end

  defp resolve_output_stream_format(state) do
    case state.output_stream_format do
      format when is_struct(format) ->
        state

      module when is_atom(module) ->
        %{state | output_stream_format: struct(module)}

      resolver when is_function(resolver) ->
        %{state | output_stream_format: resolver.(state.input_stream_format)}
        |> resolve_output_stream_format()
    end
  end

  defp plug_transcoding(builder, input_format, output_format)
       when Audio.is_audio_format(input_format) do
    builder |> Audio.plug_audio_transcoding(input_format, output_format)
  end

  defp plug_transcoding(builder, input_format, output_format)
       when Video.is_video_format(input_format) do
    builder |> Video.plug_video_transcoding(input_format, output_format)
  end
end
