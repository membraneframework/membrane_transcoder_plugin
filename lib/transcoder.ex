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
  * `Membrane.RemoteStream{content_type: Membrane.Opus}` (only as an input stream)
  """
  use Membrane.Bin

  require __MODULE__.Audio
  require __MODULE__.Video
  require Membrane.Logger

  alias __MODULE__.{Audio, Video}
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
                spec:
                  stream_format()
                  | stream_format_module()
                  | stream_format_resolver(),
                description: """
                An option specifying desired output format.

                Can be either:
                * a struct being a Membrane stream format,
                * a module in which Membrane stream format struct is defined,
                * a function which receives input stream format as an input argument
                and is supposed to return the desired output stream format or its module.
                """
              ],
              transcoding_policy: [
                spec: :always | :if_needed | :never,
                default: :if_needed,
                description: """
                Specifies, when transcoding should be appliead.

                Can be either:
                * an atom: `:always`, `:if_needed` (default) or `:never`,
                * a function that receives the input stream format and returns an atom.

                If set to `:always`, the input media stream will be decoded and encoded, even
                if the input stream format and the output stream format are the same type.

                If set to `:if_needed`, the input media stream will be transcoded only if the input
                stream format and the output stream format are different types.
                This is the default behavior.

                If set to `:never`, the input media stream won't be neither decoded nor transcoded.
                Changing alignment, encapsulation or stream structure is still possible. This option
                is helpful when you want to ensure that #{inspect(__MODULE__)} will not use too much
                of resources, e.g. CPU or memory.
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    spec = [
      bin_input()
      |> child(:connector, %Membrane.Connector{notify_on_stream_format?: true}),
      child(:output_funnel, Funnel)
      |> bin_output()
    ]

    state =
      opts
      |> Map.from_struct()
      |> Map.merge(%{
        input_stream_format: nil
      })

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification({:stream_format, _pad, format}, :connector, _ctx, state)
      when state.input_stream_format == nil do
    state =
      %{state | input_stream_format: format}
      |> resolve_output_stream_format()

    state =
      with %{transcoding_policy: f} when is_function(f) <- state do
        %{state | transcoding_policy: f.(format)}
      end

    spec =
      get_child(:connector)
      |> plug_transcoding(
        format,
        state.output_stream_format,
        state.transcoding_policy
      )
      |> get_child(:output_funnel)

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification({:stream_format, _pad, new_format}, :connector, _ctx, state) do
    %new_stream_format_module{} = new_format
    %old_stream_format_module{} = state.input_stream_format

    if new_stream_format_module != old_stream_format_module do
      raise """
      Received new stream format on transcoder's input: #{inspect(new_format)}
      which doesn't match the first received input stream format: #{inspect(state.input_stream_format)}
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

  defp plug_transcoding(builder, input_format, output_format, transcoding_policy)
       when Audio.is_audio_format(input_format) do
    builder
    |> Audio.plug_audio_transcoding(input_format, output_format, transcoding_policy)
  end

  defp plug_transcoding(builder, input_format, output_format, transcoding_policy)
       when Video.is_video_format(input_format) do
    builder
    |> Video.plug_video_transcoding(input_format, output_format, transcoding_policy)
  end
end
