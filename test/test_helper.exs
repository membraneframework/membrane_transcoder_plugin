# System.schedulers_online() * 2 is the default value of max_cases

max_cases =
  if System.get_env("CIRCLECI") == "true",
    do: 1,
    else: System.schedulers_online() * 2

exclude = if Membrane.Transcoder.vulkan_available?(), do: [], else: [:vulkan]
ExUnit.start(capture_log: true, max_cases: max_cases, exclude: exclude)
