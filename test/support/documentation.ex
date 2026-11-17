defmodule AshHooks.Test.Documentation do
  @moduledoc false

  alias Ecto.Adapters.SQL

  @formatter_deps ~w(ash spark ecto ecto_sql plug oban ash_postgres ash_sqlite)a
  @marker ~r/^[ \t]*(?:> )*<!-- (?:tested: ([a-z0-9-]+)|not-run: ([^\n]*)) -->[ \t]*$/

  def package_files do
    Mix.Project.config()[:package][:files]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.flat_map(fn path ->
      if File.dir?(path), do: Path.wildcard(Path.join(path, "**/*")), else: [path]
    end)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  def guides do
    extras =
      Enum.map(Mix.Project.config()[:docs][:extras], fn
        {path, _options} -> path
        path -> path
      end)

    (package_files() ++ extras)
    |> Enum.flat_map(fn path ->
      if File.dir?(path), do: Path.wildcard(Path.join(path, "**/*")), else: [path]
    end)
    |> Enum.filter(&(Path.extname(&1) in [".md", ".livemd"]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def documents do
    Enum.map(guides(), &{&1, File.read!(&1)}) ++ module_documents()
  end

  defp module_documents do
    {:ok, modules} = :application.get_key(:ash_hooks, :modules)

    for module <- modules,
        source = to_string(module.module_info(:compile)[:source]),
        [_, relative] <- [Regex.run(~r{(?:^|/)lib/(.+)$}, source)],
        file = "lib/" <> relative,
        File.regular?(file),
        {:docs_v1, _, _, "text/markdown", moduledoc, _, docs} <- [Code.fetch_docs(module)],
        {label, %{"en" => text}} <-
          [
            {"#{inspect(module)} @moduledoc", moduledoc}
            | Enum.map(docs, &{inspect(elem(&1, 0)), elem(&1, 3)})
          ],
        do: {"#{file} (#{label})", text}
  end

  def blocks(file), do: file |> File.read!() |> parse(file)

  def parse(text, file) do
    {nodes, _context} =
      EarmarkParser.Parser.parse_markdown(text, %EarmarkParser.Options{file: file})

    lines = String.split(text, "\n")

    code_nodes(nodes)
    |> Enum.map(fn node ->
      previous =
        lines
        |> Enum.take(node.lnb - 1)
        |> Enum.with_index(1)
        |> Enum.reverse()
        |> Enum.find(fn {line, _} -> String.trim(line) != "" end)

      {marker, marker_line} = previous || {"", 0}
      {name, reason} = disposition(marker)

      opening =
        lines |> Enum.at(node.lnb - 1) |> String.trim_leading() |> String.trim_leading("> ")

      fenced? = String.starts_with?(opening, ["```", "~~~"])

      %{
        file: file,
        line: node.lnb,
        last_line: node.lnb + length(node.lines) + if(fenced?, do: 1, else: -1),
        marker_line: if(Regex.match?(@marker, marker), do: marker_line),
        name: name,
        reason: reason,
        language: if(node.language in [nil, ""], do: "elixir", else: node.language),
        code: Enum.join(node.lines, "\n") <> "\n"
      }
    end)
  end

  defp disposition(line) do
    case Regex.run(@marker, line, capture: :all_but_first) do
      [name] -> {name, nil}
      ["", reason] -> {nil, String.trim(reason)}
      _ -> {nil, nil}
    end
  end

  defp code_nodes(nodes) do
    Enum.flat_map(nodes, fn
      %EarmarkParser.Block.Code{} = code -> [code]
      %{blocks: children} -> code_nodes(children)
      _ -> []
    end)
  end

  def all_blocks, do: Enum.flat_map(documents(), fn {file, text} -> parse(text, file) end)

  def block(name) do
    [block] = Enum.filter(all_blocks(), &(&1.name == name))
    block
  end

  def validate_manifest!(documents) do
    blocks = Enum.flat_map(documents, fn {file, text} -> parse(text, file) end)
    Enum.each(blocks, &validate_block!/1)

    for {name, copies} <- Enum.group_by(Enum.filter(blocks, & &1.name), & &1.name),
        length(copies) != 1 do
      raise "duplicate tested marker: #{name}"
    end

    for {file, text} <- documents,
        {line, number} <- Enum.with_index(String.split(text, "\n"), 1),
        Regex.match?(~r/<!--\s*(?:tested|not-run)\b/, line),
        not Enum.any?(blocks, &(&1.file == file and number in &1.line..&1.last_line)) do
      unless Regex.match?(@marker, line), do: raise("#{file}:#{number}: malformed disposition")

      unless Enum.count(blocks, &(&1.file == file and &1.marker_line == number)) == 1,
        do: raise("#{file}:#{number}: orphan disposition")
    end

    blocks
  end

  defp validate_block!(block) do
    unless block.marker_line, do: fail!(block, "unmarked #{block.language} block")

    if block.reason in ["", "example"],
      do: fail!(block, "not-run needs a specific nonempty reason")

    if is_nil(block.reason) do
      unless block.language in ["elixir", "sql", "sh"],
        do: fail!(block, "no runner for #{block.language}; supply a not-run reason")

      validate_placeholders!(block)
    end
  end

  def validate_execution!(blocks, completed) do
    required = for block <- blocks, is_nil(block.reason), do: block.name
    missing = required -- completed
    unexpected = completed -- required

    unless missing == [] and unexpected == [],
      do:
        raise(
          "executed examples differ: missing #{inspect(missing)}, unexpected #{inspect(unexpected)}"
        )

    :ok
  end

  def validate_placeholders!(%{language: "elixir"} = block) do
    case Code.string_to_quoted(block.code) do
      {:ok, _} -> :ok
      {:error, _} -> fail!(block, "invalid executable Elixir or template syntax")
    end
  end

  def validate_placeholders!(block) do
    # Remove language literals and comments before looking for template operands.
    literals =
      case block.language do
        "sql" ->
          ~r/'(?:[^']|'')*'|"(?:[^"]|"")*"|\$([a-zA-Z_]\w*)?\$.*?\$\1\$|--[^\n]*|\/\*.*?\*\//s

        "sh" ->
          ~r/'[^']*'|"(?:[^"\\]|\\.)*"|\#[^\n]*/s
      end

    executable = Regex.replace(literals, block.code, " ")

    if Regex.match?(~r/<(?:[a-zA-Z_][a-zA-Z0-9_ .-]*|\.\.\.)>/, executable),
      do: fail!(block, "template syntax in executable position")

    :ok
  end

  def validate_dashes!(documents) do
    offenses =
      for {path, text} <- documents,
          {line, number} <- Enum.with_index(String.split(text, "\n"), 1),
          String.contains?(line, [<<0x2013::utf8>>, <<0x2014::utf8>>]),
          do: "#{path}:#{number}"

    unless offenses == [], do: raise(Enum.join(offenses, "\n"))
    :ok
  end

  def track_test(context) do
    Process.put({__MODULE__, :test}, {context.module, context.test})
    :ok
  end

  def completed!(names) do
    if test = Process.get({__MODULE__, :test}) do
      AshHooks.Test.DocumentationRuns.completed(test, Enum.reject(names, &is_nil/1))
    end

    :ok
  end

  def validate_run!(blocks) do
    validate_execution!(blocks, AshHooks.Test.DocumentationRuns.completed_names())
  end

  def formatter_options do
    locals =
      Enum.flat_map(@formatter_deps, fn dep ->
        case Mix.Project.deps_paths()[dep] do
          nil ->
            []

          path ->
            {options, _} = Code.eval_file(Path.join(path, ".formatter.exs"))
            options[:export][:locals_without_parens] || []
        end
      end)

    {own, _} = Code.eval_file(".formatter.exs")

    [
      line_length: 98,
      locals_without_parens: Enum.uniq(locals ++ own[:export][:locals_without_parens])
    ]
  end

  def validate_format!(blocks) do
    options = formatter_options()

    offenders =
      blocks
      |> Enum.filter(&(&1.language == "elixir"))
      |> Enum.flat_map(fn block ->
        try do
          formatted = block.code |> Code.format_string!(options) |> IO.iodata_to_binary()

          if formatted <> "\n" == block.code,
            do: [],
            else: ["#{block.file}:#{block.line}: Elixir block is not consumer-formatted"]
        rescue
          error in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
            ["#{block.file}:#{block.line}: invalid Elixir block: #{Exception.message(error)}"]
        end
      end)

    unless offenders == [], do: raise(Enum.join(offenders, "\n"))
    :ok
  end

  def run!(%{language: "sql"} = block, repo) do
    # Each shipped statement is sent unchanged to the real adapter. Statements
    # are separated only at semicolons, outside quoted strings and SQL comments.
    results = block.code |> sql_statements() |> Enum.map(&SQL.query!(repo, &1, []))
    completed!([block[:name]])
    results
  end

  def run!(%{language: "sh"} = block, directory) do
    {output, status} =
      System.cmd("sh", ["-eu", "-c", block.code], cd: directory, stderr_to_stdout: true)

    unless status == 0, do: fail!(block, "shell command exited #{status}: #{output}")
    completed!([block[:name]])
    :ok
  end

  def sql_statements(code) do
    ~r/(?:'[^']*(?:''[^']*)*'|"[^"]*(?:""[^"]*)*"|--[^\n]*(?:\n|$)|[^;'"-]+|-(?!-))+/s
    |> Regex.scan(code)
    |> Enum.map(&hd/1)
    |> Enum.reject(&(String.trim(Regex.replace(~r/--[^\n]*/, &1, "")) == ""))
  end

  defp fail!(block, message), do: raise("#{block.file}:#{block.line}: #{message}")

  def ast(name), do: name |> block() |> Map.fetch!(:code) |> Code.string_to_quoted!()

  def lexical(ast) do
    Macro.prewalk(ast, fn
      {:__aliases__, meta, parts} -> {:__aliases__, Keyword.delete(meta, :alias), parts}
      other -> other
    end)
  end

  def namespace(name), do: Module.concat([__MODULE__, Macro.camelize(name)])

  def compile(name) do
    namespace = namespace(name)
    ast = ast(name)

    code =
      case ast do
        {:defmodule, _, _} ->
          ast

        _ ->
          quote do
            defmodule Provider do
              @moduledoc false
              unquote(ast)
            end
          end
      end

    modules =
      quote do
        defmodule unquote(namespace) do
          unquote(code)
        end
      end
      |> lexical()
      |> Code.compile_quoted(block(name).file)
      |> Enum.map(&elem(&1, 0))

    completed!([name])
    Enum.find(modules, &function_exported?(&1, :verify_signature, 3)) || namespace
  end

  def eval(name, namespace, binding \\ []) do
    ast = ast(name)

    code =
      if String.contains?(block(name).code, "MyApp.") do
        quote do
          alias unquote(Module.concat(namespace, MyApp)), as: MyApp
          unquote(ast)
        end
      else
        ast
      end

    result = code |> lexical() |> Code.eval_quoted(binding)
    completed!([name])
    result
  end

  # Independent signed messages for the application-defined contracts in the
  # guide. These use OTP's actual cryptographic implementations, never adapters.
  def vector(name) do
    body = ~s({"type":"order.paid","id":"event-1","created_at":123,"event_id":"signed-1"})
    now = System.system_time(:second)
    ts = Integer.to_string(now)
    ms = Integer.to_string(now * 1_000)
    key = :crypto.strong_rand_bytes(32)
    ctx = %{headers: %{}, method: "POST", request_uri: "https://hooks.example.com/a%2Fb?q=1"}

    {input, header, format, secret, extra} = contract(name, body, ctx, now, ts, ms, key)

    digest = if format == :sha512, do: :sha512, else: :sha256
    mac = :crypto.mac(:hmac, digest, key, input)
    hex = Base.encode16(mac, case: :lower)

    signature =
      case format do
        :base64 -> Base.encode64(mac)
        :standard -> "v1," <> Base.encode64(mac)
        :structured -> "t=#{ts},v1=bad,v1=#{hex}"
        :prefix -> "sha256=" <> hex
        _ -> hex
      end

    {body, %{ctx | headers: Map.put(extra, header, signature)}, secret}
  end

  defp contract("readme-payments-provider", body, _ctx, _now, ts, _ms, key) do
    {ts <> "." <> body, "x-payments-signature", :structured, key, %{}}
  end

  defp contract("upgrade-shop-provider", body, _ctx, _now, _ts, _ms, key) do
    {body, "x-shop-signature", :base64, key, %{}}
  end

  defp contract("verify-shop-provider", body, _ctx, _now, _ts, _ms, key) do
    {body, "x-shop-signature", :base64, key, %{}}
  end

  defp contract("verify-prefixed-provider-in-application", body, _ctx, _now, _ts, _ms, key) do
    {body, "x-hook-signature", :prefix, key, %{}}
  end

  defp contract("verify-encoded-key-provider-in-application", body, _ctx, _now, _ts, _ms, key) do
    {body, "x-encoded-key-signature", :hex, Base.encode16(key, case: :lower), %{}}
  end

  defp contract("verify-structured-provider-in-application", body, _ctx, _now, ts, _ms, key) do
    {ts <> "." <> body, "x-payments-signature", :structured, key, %{}}
  end

  defp contract("verify-standard-provider-in-application", body, _ctx, _now, ts, _ms, key) do
    {"msg_1." <> ts <> "." <> body, "webhook-signature", :standard,
     "whsec_" <> Base.encode64(key), %{"webhook-id" => "msg_1", "webhook-timestamp" => ts}}
  end

  defp contract("verify-request-provider-in-application", body, ctx, _now, _ts, ms, key) do
    {ctx.method <> ctx.request_uri <> body <> ms, "x-request-signature", :base64, key,
     %{"x-request-timestamp" => ms}}
  end

  defp contract("verify-crm-provider", body, ctx, _now, _ts, ms, key) do
    {ctx.method <> "https://hooks.example.com/a/b?q=1" <> body <> ms, "x-request-signature",
     :base64, key, %{"x-request-timestamp" => ms}}
  end

  defp contract("verify-fields-provider", _body, _ctx, _now, _ts, _ms, key) do
    {"123.signed-1", "x-fields-signature", :base64, key, %{}}
  end

  defp contract("verify-date-provider", body, _ctx, now, _ts, _ms, key) do
    date = DateTime.from_unix!(now) |> Calendar.strftime("%a, %d %b %Y %H:%M:%S +0000")

    {date <> "POST/a%2Fb" <> body, "x-dated-signature", :prefix, key, %{"x-timestamp" => date}}
  end

  defp contract("verify-migrating-provider", body, _ctx, _now, _ts, _ms, key) do
    {body, "x-signature", :hex, key, %{}}
  end

  defp contract("verify-custom-provider", body, _ctx, _now, _ts, _ms, key) do
    {"nonce-1:" <> body, "x-signature", :sha512, key, %{"x-nonce" => "nonce-1"}}
  end

  defp contract(_, body, _ctx, _now, _ts, _ms, key) do
    {body, "x-orders-signature", :hex, key, %{}}
  end

  def rsa_vector(jws?) do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPublicKey, public)])
    body = ~s({"id":"event-1","type":"order.paid"})

    if jws? do
      header = Base.url_encode64(~s({"alg":"RS256"}), padding: false)
      input = header <> "." <> Base.url_encode64(body, padding: false)
      sig = :public_key.sign(input, :sha256, private) |> Base.url_encode64(padding: false)
      {input <> "." <> sig, %{headers: %{}}, pem}
    else
      sig = :public_key.sign(Base.encode64(body), :sha256, private) |> Base.encode64()
      {body, %{headers: %{"x-rsa-signature" => sig}}, pem}
    end
  end
end
