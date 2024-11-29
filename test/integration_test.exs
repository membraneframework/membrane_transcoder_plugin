defmodule Membrane.Agora.IntegrationTest do
  use ExUnit.Case
  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.Testing.Pipeline

  @test_cases [
    {"input.h264", Membrane.H265},
    {"input.h264", Membrane.H264},
    {"input.h264", Membrane.VP8}
  ]

  Enum.map(@test_cases, fn {input_file, output_module} ->
    test "if #{inspect(input_file)} stream is transcoded to #{inspect(output_module)}" do
      pid = Pipeline.start_link_supervised!()

      spec =
        child(%Membrane.File.Source{
          location: Path.join("./test/fixtures", unquote(input_file))
        })
        |> child(%Membrane.H264.Parser{generate_best_effort_timestamps: %{framerate: {30, 1}}})
        |> child(%Membrane.Transcoder{output_stream_format: unquote(output_module)})
        |> child(:sink, Membrane.Testing.Sink)

      Pipeline.execute_actions(pid, spec: spec)

      assert_sink_stream_format(pid, :sink, %unquote(output_module){})
      Pipeline.terminate(pid)
    end
  end)
end
