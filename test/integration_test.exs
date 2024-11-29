defmodule Membrane.Agora.IntegrationTest do
  use ExUnit.Case
  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.Testing.Pipeline

  test "if H264 stream is transcoded to H265" do
    pid = Pipeline.start_link_supervised!()

    filename = "input.h264"

    output_stream_format = Membrane.H265

    spec =
      child(%Membrane.File.Source{location: Path.join("./test/fixtures", filename)})
      |> child(%Membrane.H264.Parser{generate_best_effort_timestamps: %{framerate: {30, 1}}})
      |> child(%Membrane.Transcoder{output_stream_format: output_stream_format})
      |> child(:sink, Membrane.Testing.Sink)

    Pipeline.execute_actions(pid, spec: spec)

    assert_sink_stream_format(pid, :sink, %Membrane.H265{})
    Pipeline.terminate(pid)
  end
end
