defmodule Membrane.Transcoder do
  @moduledoc """
  Provides transcoding capabilities for audio and video streams in Membrane.

  The bin takes an incoming stream on its input and converts it into the desired one
  as specified by the option. Transcoding is applied only if it is neccessary.
  The following video stream formats are supported:
  * `Membrane.H264`
  * `Membrane.H265`
  * `Membrane.VP8`
  * `Membrane.VP9`
  * `Membrane.RawVideo`
  * `Membrane.RemoteStream{content_format: Membrane.VP8}` (only as an input stream)
  * `Membrane.RemoteStream{content_format: Membrane.VP9}` (only as an input stream)

  The following audio stream formats are supported:
  * `Membrane.AAC`
  * `Membrane.Opus`
  * `Membrane.MPEGAudio`
  * `Membrane.RawAudio`
  * `Membrane.RemoteStream{content_format: Membrane.Opus}` (only as an input stream)
  * `Membrane.RemoteStream{content_format: Membrane.MPEGAudio}` (only as an input stream)

  While `#{inspect(__MODULE__)}` can transcode between different stream formats, it can also be used
  to change some parameters of the stream format.
  Now, the only supported stream parameters are:
  * `:pixel_format` in `Membrane.RawVideo`
  * `:alignment` and `:stream_structure` in `Membrane.H264` and `Membrane.H265`

  When the `membrane_vk_video_plugin` dependency is present and Vulkan hardware is available,
  H.264 encode/decode can be offloaded to the GPU by setting `native_acceleration: :if_available`.

  ## Usage

      child(:transcoder, Membrane.Transcoder),
      get_child(:transcoder)
      |> via_out(Pad.ref(:output, 0), options: [output_stream_format: H264, transcoding_policy: :if_needed])
      |> child(:h264_sink, Membrane.File.Sink),
      get_child(:transcoder)
      |> via_out(Pad.ref(:output, 1), options: [output_stream_format: H265, transcoding_policy: :always])
      |> child(:h265_sink, Membrane.File.Sink)
  """
  use Membrane.Bin

  require __MODULE__.Audio
  require __MODULE__.Video
  require Membrane.Logger
  require Membrane.Pad

  alias __MODULE__.{Audio, Video}
  alias Membrane.{AAC, Funnel, H264, H265, Opus, Pad, RawAudio, RawVideo, RemoteStream, VP8, VP9}

  @typedoc """
  Describes stream formats acceptable on the bin's input and output.
  """
  @type stream_format ::
          H264.t()
          | H265.t()
          | VP8.t()
          | VP9.t()
          | RawVideo.t()
          | AAC.t()
          | Opus.t()
          | Membrane.MPEGAudio.t()
          | RemoteStream.t()
          | RawAudio.t()

  @typedoc """
  Describes stream format modules that can be used to define inputs and outputs of the bin.
  """
  @type stream_format_module ::
          H264 | H265 | VP8 | VP9 | RawVideo | AAC | Opus | Membrane.MPEGAudio | RawAudio

  @typedoc """
  Describes a tuple consisting of a stream format module and its options.

  An alternative to `t:#{inspect(__MODULE__)}.stream_format/0`.

  Allows you to specify some fields of the output stream format, without the need to
  set all keys required by the struct.
  """
  @type stream_format_tuple :: {stream_format_module(), keyword()}

  @typedoc """
  Describes a function which can be used to provide output format based on the input format.
  """
  @type stream_format_resolver :: (stream_format() -> stream_format() | stream_format_module())

  def_input_pad :input,
    accepted_format:
      format
      when Audio.is_audio_format(format) or Video.is_video_format(format) or
             format.__struct__ == RemoteStream

  def_output_pad :output,
    availability: :on_request,
    accepted_format: format when Audio.is_audio_format(format) or Video.is_video_format(format),
    options: [
      output_stream_format: [
        spec:
          stream_format()
          | stream_format_module()
          | stream_format_tuple()
          | stream_format_resolver()
          | nil,
        default: nil,
        description: """
        Per-output stream format. Inherits from bin's `output_stream_format` option if nil.
        """
      ],
      transcoding_policy: [
        spec:
          :always
          | :if_needed
          | :never
          | (stream_format() -> :always | :if_needed | :never)
          | nil,
        default: nil,
        description: """
        Per-output transcoding policy. Inherits from bin's `transcoding_policy` option if nil.
        """
      ],
      native_acceleration: [
        spec: :never | :if_available | nil,
        default: nil,
        description: """
        Per-output native acceleration setting. Inherits from bin's `native_acceleration` option if nil.
        """
      ]
    ]

  def_options output_stream_format: [
                spec:
                  stream_format()
                  | stream_format_module()
                  | stream_format_tuple()
                  | stream_format_resolver()
                  | nil,
                default: nil,
                description: """
                An option specifying the desired output format for all outputs.

                Can be either:
                * a struct being a Membrane stream format,
                * a module in which Membrane stream format struct is defined,
                * a function which receives input stream format as an input argument
                and is supposed to return the desired output stream format or its module.

                When using per-output `via_out` options, individual outputs can override this value.
                """
              ],
              transcoding_policy: [
                spec:
                  :always
                  | :if_needed
                  | :never
                  | (stream_format() -> :always | :if_needed | :never),
                default: :if_needed,
                description: """
                Specifies, when transcoding should be applied.

                Can be either:
                * an atom: `:always`, `:if_needed` (default) or `:never`,
                * a function that receives the input stream format and returns either `:always`,
                  `:if_needed` or `:never`.

                If set to `:always`, the input media stream will be decoded and encoded, even
                if the input stream format and the output stream format are the same type.

                If set to `:if_needed`, the input media stream will be transcoded only if the input
                stream format and the output stream format are different types.
                This is the default behavior.

                If set to `:never`, the input media stream won't be neither decoded nor encoded.
                Changing alignment, encapsulation or stream structure is still possible. This option
                is helpful when you want to ensure that #{inspect(__MODULE__)} will not use too much
                of resources, e.g. CPU or memory.

                If the transition from the input stream format to the output stream format is not
                possible without decoding or encoding the stream, an error will be raised.
                """
              ],
              assumed_input_stream_format: [
                spec: struct() | nil,
                default: nil,
                description: """
                Allows to override stream format of the input stream.

                Overriding will fail, the stream format sent on the #{inspect(__MODULE__)}'s input
                pad is not `Membrane.RemoteStream`

                If nil or not set, the input stream format won't be overriden.
                """
              ],
              native_acceleration: [
                spec: :never | :if_available,
                default: :never,
                description: """
                Specifies whether to use Vulkan hardware acceleration for video transcoding.

                Can be:
                * `:never` - Always use software-based transcoding (default)
                * `:if_available` - Use Vulkan acceleration when available on the system
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    spec =
      bin_input()
      |> maybe_plug_stream_format_changer(opts.assumed_input_stream_format)
      |> child(:connector, %Membrane.Connector{notify_on_stream_format?: true})

    state =
      opts
      |> Map.from_struct()
      |> Map.merge(%{
        input_stream_format: nil,
        output_specs: %{}
      })

    {[spec: spec], state}
  end

  defp should_use_hardware_acceleration?(:if_available), do: vulkan_available?()
  defp should_use_hardware_acceleration?(_native_acceleration), do: false

  @doc """
  Returns `true` if the optional `membrane_vk_video_plugin` dependency is installed
  and its modules can be loaded in the current runtime.

  Note: a `true` result only confirms the plugin is loadable - it does not guarantee that the
  host actually exposes Vulkan Video extensions with H.264 encode/decode capabilities. The
  underlying plugin may still fail at runtime if the GPU/driver does not support them.
  """
  @spec vulkan_available?() :: boolean()
  def vulkan_available?() do
    Code.ensure_loaded?(Membrane.VKVideo.Decoder) and
      Code.ensure_loaded?(Membrane.VKVideo.Encoder) and
      Code.ensure_loaded?(Membrane.VKVideo.Native)
  end

  defp maybe_plug_stream_format_changer(builder, nil), do: builder

  defp maybe_plug_stream_format_changer(builder, enforced_stream_format) do
    builder
    |> child(:stream_format_changer, %__MODULE__.StreamFormatChanger{
      stream_format: enforced_stream_format
    })
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, pad_id) = pad_ref, ctx, state) do
    pad_opts = ctx.pads[pad_ref].options

    suffix = {pad_id, :output}
    funnel_name = {pad_id, :output, :funnel}

    output_spec = %{
      output_stream_format: pad_opts.output_stream_format || state.output_stream_format,
      transcoding_policy: pad_opts.transcoding_policy || state.transcoding_policy,
      native_acceleration: pad_opts.native_acceleration || state.native_acceleration,
      funnel_name: funnel_name,
      suffix: suffix,
      pad_id: pad_id
    }

    spec = child(funnel_name, Funnel) |> bin_output(pad_ref)

    {[spec: spec], %{state | output_specs: Map.put(state.output_specs, pad_ref, output_spec)}}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, _id) = pad_ref, _ctx, state) do
    {[], %{state | output_specs: Map.delete(state.output_specs, pad_ref)}}
  end

  @impl true
  def handle_child_notification({:stream_format, _pad, format}, :connector, _ctx, state)
      when state.input_stream_format == nil do
    state = %{state | input_stream_format: format}

    output_specs_list = Map.to_list(state.output_specs)
    single_output? = length(output_specs_list) == 1

    specs =
      if single_output? do
        [{_pad_ref, output_spec}] = output_specs_list
        use_hw? = should_use_hardware_acceleration?(output_spec.native_acceleration)
        resolved_format = resolve_output_stream_format(output_spec.output_stream_format, format)

        transcoding_policy = resolve_transcoding_policy(output_spec.transcoding_policy, format)

        [
          get_child(:connector)
          |> plug_transcoding(
            format,
            resolved_format,
            transcoding_policy,
            use_hw?,
            output_spec.suffix
          )
          |> get_child(output_spec.funnel_name)
        ]
      else
        # Build tee and all output pipelines in a single spec so the tee
        # is never in a state where data flows through it without outputs connected.
        tee_spec = get_child(:connector) |> child(:tee, Membrane.Tee.Parallel)

        output_pipeline_specs =
          Enum.map(output_specs_list, fn {_pad_ref, output_spec} ->
            use_hw? = should_use_hardware_acceleration?(output_spec.native_acceleration)

            resolved_format =
              resolve_output_stream_format(output_spec.output_stream_format, format)

            transcoding_policy =
              resolve_transcoding_policy(output_spec.transcoding_policy, format)

            get_child(:tee)
            |> via_out(Pad.ref(:output, output_spec.pad_id))
            |> plug_transcoding(
              format,
              resolved_format,
              transcoding_policy,
              use_hw?,
              output_spec.suffix
            )
            |> get_child(output_spec.funnel_name)
          end)

        [tee_spec | output_pipeline_specs]
      end

    {[spec: specs], state}
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

  defp resolve_transcoding_policy(f, format) when is_function(f), do: f.(format)
  defp resolve_transcoding_policy(policy, _format), do: policy

  defp resolve_output_stream_format(nil, input_format), do: input_format

  defp resolve_output_stream_format(output_stream_format, input_format) do
    case output_stream_format do
      format when is_struct(format) ->
        format

      module when is_atom(module) ->
        struct(module)

      {module, opts} when is_atom(module) and is_list(opts) ->
        struct(module, opts)

      resolver when is_function(resolver) ->
        resolve_output_stream_format(resolver.(input_format), input_format)
    end
  end

  defp plug_transcoding(
         builder,
         input_format,
         output_format,
         transcoding_policy,
         _use_hardware_acceleration?,
         suffix
       )
       when Audio.is_audio_format(input_format) do
    builder
    |> Audio.plug_audio_transcoding(input_format, output_format, transcoding_policy, suffix)
  end

  defp plug_transcoding(
         builder,
         input_format,
         output_format,
         transcoding_policy,
         use_hardware_acceleration?,
         suffix
       )
       when Video.is_video_format(input_format) do
    builder
    |> Video.plug_video_transcoding(
      input_format,
      output_format,
      transcoding_policy,
      use_hardware_acceleration?,
      suffix
    )
  end
end
