defmodule AshHooks.Test.HttpReceiver do
  @moduledoc false
  # OTP's real HTTP server, not a socket peer emulating canned HTTP. Each test
  # owns a listener; its handler reports the parsed request the server received.
  require Record
  Record.defrecordp(:request, :mod, Record.extract(:mod, from_lib: "inets/include/httpd.hrl"))

  def start(opts \\ []) do
    config = [
      port: 0,
      bind_address: {127, 0, 0, 1},
      server_name: :erlang.pid_to_list(self()),
      server_root: String.to_charlist(Path.expand("test")),
      document_root: String.to_charlist(Path.expand("test")),
      modules: [__MODULE__]
    ]

    {:ok, server} = :inets.start(:httpd, config ++ opts)
    port = server |> :httpd.info() |> Keyword.fetch!(:port)
    {server, port}
  end

  def unquote(:do)(info) do
    owner = :httpd_util.lookup(request(info, :config_db), :server_name) |> :erlang.list_to_pid()

    headers =
      Map.new(request(info, :parsed_header), fn {k, v} -> {to_string(k), to_string(v)} end)

    path = to_string(request(info, :request_uri))

    send(
      owner,
      {:http_received,
       %{path: path, headers: headers, body: IO.iodata_to_binary(request(info, :entity_body))}}
    )

    status = path |> String.split("/") |> List.last() |> String.to_integer()

    {:proceed,
     [
       response:
         {:response,
          [code: status, content_length: ~c"2", content_type: ~c"text/plain", retry_after: ~c"7"],
          "ok"}
     ]}
  end
end
