# Membrane Transcoder Plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_transcoder_plugin.svg)](https://hex.pm/packages/membrane_transcoder_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_transcoder_plugin)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_transcoder_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_transcoder_plugin)

This repository provides `Membrane.Transcoder` which is a bin that is capable 
of transcoding the input audio or video stream into the descired one specified 
with simple declarative API.

It's a part of the [Membrane Framework](https://membrane.stream).

## Installation

The package can be installed by adding `membrane_transcoder_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_transcoder_plugin, "~> 0.1.2"}
  ]
end
```

## Usage
In the `examples/vp8_to_h264.exs` file there is an example showing how to use 
the `Membrane.Transcoder` to convert video encoded with VP8 into H264 encoded video.
You can run it with the following command:
```
elixir vp8_to_h264.exs
```

Then you can inspect the format of the output file with e.g. `ffprobe` and confirm that it stores video encoded with H.264:
```
ffprobe tmp/video.ivf
```
## Copyright and License

Copyright 2020, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_transcoder_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_transcoder_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)
