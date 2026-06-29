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

  alias __MODULE__.{Audio, OutputFormat, Video}

  alias Membrane.{
    AAC,
    Funnel,
    H264,
    H265,
    MPEGAudio,
    Opus,
    Pad,
    RawAudio,
    RawVideo,
    RemoteStream,
    VP8,
    VP9
  }

  @type input_stream_format ::
          H264.t()
          | H265.t()
          | VP8.t()
          | VP9.t()
          | RawVideo.t()
          | AAC.t()
          | Opus.t()
          | MPEGAudio.t()
          | RemoteStream.t()
          | RawAudio.t()

  @typedoc """
  Describes a function which can be used to provide output format based on the input format.
  """
  @type output_format_resolver :: (input_stream_format() -> OutputFormat.t())

  @type transcoding_policy ::
          :always
          | :if_needed
          | :never
          | (input_stream_format() -> :always | :if_needed | :never)

  @type native_acceleration :: :never | :if_available

  @typedoc """
  Describes bitrate option for video transcoding.
  Can be either a ConstantBitrate or VariableBitrate struct.
  """
  @type bitrate_option ::
          Membrane.Transcoder.Video.ConstantBitrate.t()
          | Membrane.Transcoder.Video.VariableBitrate.t()
          | nil

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
          OutputFormat.t()
          | output_format_resolver()
          | nil,
        default: nil,
        description: """
        Per-output stream format. Inherits from bin's `output_stream_format` option if nil.

        Can be either:
        * a struct or module defined in OutputFormat module,
        * a function which receives input stream format as an input argument
          and returns the desired output format or its module.
        """
      ],
      transcoding_policy: [
        spec: transcoding_policy() | nil,
        default: nil,
        description: """
        Per-output transcoding policy. Inherits from bin's `transcoding_policy` option if nil.
        """
      ],
      native_acceleration: [
        spec: native_acceleration() | nil,
        default: nil,
        description: """
        Per-output native acceleration setting. Inherits from bin's `native_acceleration` option if nil.
        """
      ],
      bitrate: [
        spec: bitrate_option(),
        default: nil,
        description: """
        Per-output bitrate setting for video streams. Inherits from bin's `bitrate` option if nil.
        """
      ]
    ]

  def_options output_stream_format: [
                spec:
                  OutputFormat.t()
                  | output_format_resolver()
                  | nil,
                default: nil,
                description: """
                An option specifying the desired output format for all outputs.

                Can be either:
                * a struct or module defined in OutputFormat module,
                * a function which receives input stream format as an input argument
                  and returns the desired output format or its module.

                When using per-output `via_out` options, individual outputs can override this value.
                """
              ],
              transcoding_policy: [
                spec: transcoding_policy(),
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

                Overriding will fail if the stream format sent on the #{inspect(__MODULE__)}'s input
                pad is not `Membrane.RemoteStream`

                If nil or not set, the input stream format won't be overriden.
                """
              ],
              native_acceleration: [
                spec: native_acceleration(),
                default: :never,
                description: """
                Specifies whether to use Vulkan hardware acceleration for video transcoding.

                Can be:
                * `:never` - Always use software-based transcoding (default)
                * `:if_available` - Use Vulkan acceleration when available on the system
                """
              ],
              bitrate: [
                spec: bitrate_option(),
                default: nil,
                description: """
                Per-output bitrate setting for video streams.

                Can be either:
                * a `Membrane.Transcoder.Video.ConstantBitrate` struct for constant bitrate encoding
                * a `Membrane.Transcoder.Video.VariableBitrate` struct for variable bitrate encoding
                * nil (default) - use encoder defaults

                When nil, the underlying encoders use their default rate control:
                * H264 (libx264): CRF 23, preset :medium
                * H265 (libx265): CRF 28, preset :medium
                * VP8/VP9 (libvpx): VBR mode with auto target bitrate
                """
              ]

  defmodule State do
    @moduledoc false

    defmodule OutputSpecs do
      @moduledoc false

      @type t :: %__MODULE__{}

      defstruct []
    end

    @type t :: %__MODULE__{}

    defstruct []
  end

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
    funnel_name = {:funnel, suffix}

    output_spec = %{
      output_stream_format: pad_opts.output_stream_format || state.output_stream_format,
      transcoding_policy: pad_opts.transcoding_policy || state.transcoding_policy,
      native_acceleration: pad_opts.native_acceleration || state.native_acceleration,
      bitrate: pad_opts.bitrate || state.bitrate,
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
            output_spec
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
              output_spec
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
         output_spec
       )
       when Audio.is_audio_format(input_format) do
    builder
    |> Audio.plug_audio_transcoding(input_format, output_format, transcoding_policy, output_spec)
  end

  defp plug_transcoding(
         builder,
         input_format,
         output_format,
         transcoding_policy,
         use_hardware_acceleration?,
         output_spec
       )
       when Video.is_video_format(input_format) do
    builder
    |> Video.plug_video_transcoding(
      input_format,
      output_format,
      transcoding_policy,
      use_hardware_acceleration?,
      output_spec
    )
  end
end
