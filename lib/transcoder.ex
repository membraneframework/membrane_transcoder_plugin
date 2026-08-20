defmodule Membrane.Transcoder do
  @moduledoc """
  Provides transcoding capabilities for audio and video streams in Membrane.

  The bin takes an incoming stream on its input and converts it into the desired one
  as specified by the option. Transcoding is applied only if it is neccessary.
  Stream formats accepted by the transcoder are described by a
  `t:input_format/0`.

  Output stream formats can be specified by a struct from `t:Membrane.Transcoder.OutputFormat.t/0`.
  This struct determines the output stream format, as well parameters that can be set for this
  format.

  When the `membrane_vk_video_plugin` dependency is present and Vulkan hardware is available,
  H.264 encode/decode can be offloaded to the GPU by setting `native_acceleration: :if_available`.

  ## Usage

      child(:transcoder, Transcoder),
      get_child(:transcoder)
      |> via_out(Pad.ref(:output, 0), options: [output_stream_format: Transcoder.OutputFormat.H264])
      |> child(:h264_sink, Membrane.File.Sink),
      get_child(:transcoder)
      |> via_out(Pad.ref(:output, 1), options: [output_stream_format: Transcoder.OutputFormat.H265])
      |> child(:h265_sink, Membrane.File.Sink)
  """
  use Membrane.Bin

  require __MODULE__.Audio
  require __MODULE__.Video
  require Membrane.Logger
  require Membrane.Pad

  alias __MODULE__.{Audio, OutputFormat, Video}

  alias Membrane.Pad

  @output_format_modules [
    OutputFormat.H264,
    OutputFormat.H265,
    OutputFormat.VP8,
    OutputFormat.VP9,
    OutputFormat.RawVideo,
    OutputFormat.AAC,
    OutputFormat.Opus,
    OutputFormat.MPEGAudio,
    OutputFormat.RawAudio
  ]

  @type video_input_format ::
          Membrane.VP8.t()
          | Membrane.VP9.t()
          | Membrane.H264.t()
          | Membrane.H265.t()
          | Membrane.RawVideo.t()
          | %Membrane.RemoteStream{content_format: Membrane.VP8 | Membrane.VP9, type: :packetized}
          | %Membrane.RemoteStream{content_format: Membrane.H264 | Membrane.H265}

  @type audio_input_format ::
          Membrane.AAC.t()
          | Membrane.Opus.t()
          | Membrane.MPEGAudio.t()
          | Membrane.RawAudio.t()
          | %Membrane.RemoteStream{
              content_format: Membrane.AAC | Membrane.Opus | Membrane.MPEGAudio
            }

  @type input_format ::
          video_input_format()
          | audio_input_format()

  @typedoc """
  Describes a function which can be used to provide output format based on the input format.
  """
  @type output_format_resolver :: (input_format() -> OutputFormat.t())

  @type transcoding_policy ::
          :always
          | :if_needed
          | :never

  @type native_acceleration :: :never | :if_available

  @typedoc """
  Describes bitrate option for video transcoding.
  Can be either a ConstantBitrate or VariableBitrate struct.
  """
  @type bitrate_option ::
          Membrane.Transcoder.Video.ConstantBitrate.t()
          | Membrane.Transcoder.Video.VariableBitrate.t()

  @type resolution :: %{width: pos_integer(), height: pos_integer()}

  def_input_pad :input,
    accepted_format:
      format
      when Audio.is_audio_format(format) or Video.is_video_format(format) or
             format.__struct__ == Membrane.RemoteStream

  def_output_pad :output,
    availability: :on_request,
    accepted_format: format when Audio.is_audio_format(format) or Video.is_video_format(format),
    options: [
      output_stream_format: [
        spec:
          OutputFormat.t()
          | OutputFormat.mod()
          | output_format_resolver()
          | :keep,
        default: :keep,
        description: """
        Definition of the desired output stream format for this pad.

        Can be either:
        * a struct or module defined in OutputFormat module,
        * a function which receives input stream format as an input argument
          and returns the desired output format or its module.
        * `:keep` to not change the input stream format - useful if `:bitrate` or `:resolution`
          option are set to specific values.
        """
      ],
      bitrate: [
        spec: bitrate_option() | :default,
        default: :default,
        description: """
        Per-output bitrate setting, can only be set for video streams.

        Can be either:
        * a `Membrane.Transcoder.Video.ConstantBitrate` struct for constant bitrate encoding
        * a `Membrane.Transcoder.Video.VariableBitrate` struct for variable bitrate encoding
        * `:default` - use encoder defaults
        """
      ],
      resolution: [
        spec: resolution() | :keep,
        default: :keep,
        description: """
        Desired resolution of the output video stream on this pad. If set to `:keep` will keep the
        resolution of input stream. This option is valid only for video streams.
        """
      ]
    ]

  def_options assumed_input_stream_format: [
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
              transcoding_policy: [
                spec:
                  transcoding_policy()
                  | (input_format() -> transcoding_policy()),
                default: :if_needed,
                description: """
                Specifies when transcoding should be applied.

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
              ]

  defmodule State do
    @moduledoc false

    alias Membrane.Transcoder

    defmodule OutputSpec do
      @moduledoc false

      @type pad_id() :: term()

      @type t :: %__MODULE__{
              output_stream_format:
                Transcoder.OutputFormat.t()
                | Transcoder.output_format_resolver()
                | :keep,
              transcoding_policy:
                Transcoder.transcoding_policy()
                | (Transcoder.input_format() -> Transcoder.transcoding_policy()),
              native_acceleration: Transcoder.native_acceleration(),
              bitrate: Transcoder.bitrate_option() | :default,
              resolution: Transcoder.resolution() | :keep,
              pad_id: pad_id(),
              suffix: {pad_id(), :output},
              connector_name: {:connector, {pad_id(), :output}}
            }

      @enforce_keys [
        :output_stream_format,
        :transcoding_policy,
        :native_acceleration,
        :bitrate,
        :resolution,
        :pad_id,
        :suffix,
        :connector_name
      ]

      defstruct @enforce_keys
    end

    @type t :: %__MODULE__{
            assumed_input_stream_format: Transcoder.input_format() | nil,
            input_stream_format: Transcoder.input_format() | nil,
            transcoding_policy:
              Transcoder.transcoding_policy()
              | (Transcoder.input_format() -> Transcoder.transcoding_policy()),
            native_acceleration: Transcoder.native_acceleration(),
            output_specs: %{Pad.ref() => OutputSpec.t()}
          }

    @enforce_keys [
      :transcoding_policy,
      :assumed_input_stream_format,
      :native_acceleration
    ]

    defstruct @enforce_keys ++ [input_stream_format: nil, output_specs: %{}]
  end

  @impl true
  def handle_init(_ctx, opts) do
    spec =
      bin_input()
      |> maybe_plug_stream_format_changer(opts.assumed_input_stream_format)
      |> child(:input_connector, %Membrane.Connector{notify_on_stream_format?: true})

    state = struct!(State, Map.from_struct(opts))

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
  def handle_pad_added(Pad.ref(:output, pad_id) = pad_ref, ctx, %State{} = state) do
    pad_opts = ctx.pads[pad_ref].options

    suffix = {pad_id, :output}
    connector_name = {:connector, suffix}

    output_spec = %State.OutputSpec{
      output_stream_format: pad_opts.output_stream_format,
      transcoding_policy: state.transcoding_policy,
      native_acceleration: state.native_acceleration,
      bitrate: pad_opts.bitrate,
      resolution: pad_opts.resolution,
      connector_name: connector_name,
      suffix: suffix,
      pad_id: pad_id
    }

    spec = child(connector_name, Membrane.Connector) |> bin_output(pad_ref)

    {[spec: spec],
     %State{state | output_specs: Map.put(state.output_specs, pad_ref, output_spec)}}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, _id) = pad_ref, _ctx, %State{} = state) do
    {[], %State{state | output_specs: Map.delete(state.output_specs, pad_ref)}}
  end

  @impl true
  def handle_child_notification(
        {:stream_format, _pad, %Membrane.RemoteStream{content_format: nil} = format},
        :input_connector,
        _ctx,
        %State{} = state
      )
      when state.input_stream_format == nil do
    raise """
    Stream format #{inspect(format)} doesn't have enough information to be recognized, please set
    the `:assumed_input_stream_format` option to a stream format with information about it's
    the content format (e.g. `%Membrane.RemoteStream{content_format: Membrane.H264}` if the stream is
    H264) or provide a stream format with sufficient information.
    """
  end

  @impl true
  def handle_child_notification(
        {:stream_format, _pad, format},
        :input_connector,
        _ctx,
        %State{} = state
      )
      when state.input_stream_format == nil do
    state = %State{state | input_stream_format: format}

    output_specs_list = Map.to_list(state.output_specs)
    single_output? = length(output_specs_list) == 1

    specs =
      if single_output? do
        [{_pad_ref, output_spec}] = output_specs_list

        get_child(:input_connector)
        |> plug_transcoding(format, output_spec)
        |> get_child(output_spec.connector_name)
      else
        # Build tee and all output pipelines in a single spec so the tee
        # is never in a state where data flows through it without outputs connected.
        tee_spec = get_child(:input_connector) |> child(:tee, Membrane.Tee.Parallel)

        output_pipeline_specs =
          Enum.map(output_specs_list, fn {_pad_ref, output_spec} ->
            get_child(:tee)
            |> via_out(Pad.ref(:output, output_spec.pad_id))
            |> plug_transcoding(format, output_spec)
            |> get_child(output_spec.connector_name)
          end)

        [tee_spec | output_pipeline_specs]
      end

    {[spec: specs], state}
  end

  @impl true
  def handle_child_notification({:stream_format, _pad, new_format}, :input_connector, _ctx, state) do
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

  @spec resolve_transcoding_policy(
          transcoding_policy() | (input_format() -> transcoding_policy()),
          input_format()
        ) :: transcoding_policy()
  defp resolve_transcoding_policy(f, format) when is_function(f), do: f.(format)
  defp resolve_transcoding_policy(policy, _format), do: policy

  @spec resolve_output_stream_format(
          OutputFormat.t() | output_format_resolver() | :keep,
          input_format()
        ) :: OutputFormat.t()
  defp resolve_output_stream_format(output_stream_format, input_format) do
    case output_stream_format do
      :keep ->
        OutputFormat.from_input_format(input_format)

      format when is_struct(format) and format.__struct__ in @output_format_modules ->
        format

      module when is_atom(module) ->
        resolve_output_stream_format(struct(module), input_format)

      resolver when is_function(resolver) ->
        resolve_output_stream_format(resolver.(input_format), input_format)
    end
  end

  @spec plug_transcoding(ChildrenSpec.builder(), input_format(), State.OutputSpec.t()) ::
          ChildrenSpec.builder()
  defp plug_transcoding(builder, input_format, output_spec) do
    use_hardware_acceleration? =
      should_use_hardware_acceleration?(output_spec.native_acceleration)

    output_format =
      resolve_output_stream_format(output_spec.output_stream_format, input_format)

    transcoding_policy = resolve_transcoding_policy(output_spec.transcoding_policy, input_format)

    case {media_type!(input_format), media_type!(output_format)} do
      {:audio, :audio} ->
        if output_spec.bitrate != :default do
          raise """
          Bitrate option not supported for audio streams, but set to #{inspect(output_spec.bitrate)} for
          #{inspect(output_format)} stream.
          """
        end

        builder
        |> Audio.plug_audio_transcoding(
          input_format,
          output_format,
          transcoding_policy,
          output_spec
        )

      {:video, :video} ->
        builder
        |> Video.plug_video_transcoding(
          input_format,
          output_format,
          transcoding_policy,
          use_hardware_acceleration?,
          output_spec
        )

      {input_type, output_type} ->
        raise """
        Cannot transcode #{inspect(input_type)} stream #{inspect(input_format)} to \
        #{inspect(output_type)} stream #{inspect(output_format)}.
        """
    end
  end

  @spec media_type!(input_format() | OutputFormat.t()) :: :audio | :video
  defp media_type!(format) when Audio.is_audio_format(format), do: :audio
  defp media_type!(format) when Video.is_video_format(format), do: :video

  defp media_type!(format) do
    raise """
    Didn't recognize stream format #{inspect(format)}, check the `Membrane.Transcoder` moduledoc to
    see the list of supported formats. You may also set the `:assumed_input_stream_format` option with a
    stream format you want the transcoder to assume.
    """
  end
end
