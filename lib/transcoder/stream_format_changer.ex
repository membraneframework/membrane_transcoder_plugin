defmodule Membrane.Transcoder.StreamFormatChanger do
  @moduledoc false
  use Membrane.Filter

  def_input_pad :input, accepted_format: %Membrane.RemoteStream{}
  def_output_pad :output, accepted_format: _any

  def_options stream_format: [
                spec: Membrane.StreamFormat.t(),
                description: """
                Stream format that will be sent on `handle_playing`.
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{stream_format: opts.stream_format}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[stream_format: {:output, state.stream_format}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    {[buffer: {:output, buffer}], state}
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    {[], state}
  end
end
