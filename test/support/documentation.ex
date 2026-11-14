defmodule AshHooks.Test.Documentation do
  @moduledoc false

  @guides ["README.md", "UPGRADING.md", "usage-rules.md"] ++
            Path.wildcard("documentation/tutorials/*.md")

  def guides, do: @guides

  def blocks(file) do
    file |> File.read!() |> parse(file)
  end

  def parse(text, file) do
    Regex.scan(~r/(?:<!-- tested: ([a-z0-9-]+) -->\n)?```elixir\n(.*?)```/s, text, return: :index)
    |> Enum.map(fn [{offset, _length}, {marker, marker_length}, {code, code_length}] ->
      %{
        file: file,
        line: text |> binary_part(0, offset) |> String.split("\n") |> length(),
        name: if(marker_length > 0, do: binary_part(text, marker, marker_length)),
        code: binary_part(text, code, code_length)
      }
    end)
  end

  def all_blocks, do: Enum.flat_map(@guides, &blocks/1)

  def block(name) do
    [block] = Enum.filter(all_blocks(), &(&1.name == name))
    block
  end

  def validate!(files, names) do
    blocks = Enum.flat_map(files, fn {file, text} -> parse(text, file) end)
    marked = Enum.map(blocks, & &1.name)

    for block <- blocks do
      unless block.name, do: raise("#{block.file}:#{block.line}: unmarked Elixir block")
    end

    for {file, text} <- files,
        [_, name] <- Regex.scan(~r/<!-- tested: ([a-z0-9-]+) -->/, text) do
      unless Enum.count(marked, &(&1 == name)) == 1,
        do: raise("#{file}: #{name} must mark exactly one Elixir block")
    end

    unless Enum.sort(marked) == Enum.sort(names),
      do:
        raise(
          "marked blocks and executed examples differ: #{inspect(marked -- names)} / #{inspect(names -- marked)}"
        )

    :ok
  end

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

    code |> lexical() |> Code.eval_quoted(binding)
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
