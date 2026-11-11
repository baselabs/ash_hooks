defmodule AshHooks.Provider.Signature do
  @moduledoc false

  def compare(expected, actual) when is_binary(expected) and is_binary(actual) do
    if byte_size(expected) == byte_size(actual) and :crypto.hash_equals(expected, actual),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  def compare(_expected, _actual), do: {:error, :invalid_signature}

  def hmac(_body, _signature, secret, _digest, _encoding)
      when not is_binary(secret) or secret == "",
      do: {:error, :no_webhook_secret}

  def hmac(body, signature, secret, digest, encoding) when is_binary(body) do
    mac = :crypto.mac(:hmac, digest, secret, body)

    encoded =
      case encoding do
        :base64 -> Base.encode64(mac)
        :hex -> Base.encode16(mac, case: :lower)
      end

    compare(encoded, signature)
  end

  def hmac(_body, _signature, _secret, _digest, _encoding), do: {:error, :invalid_signature}

  def header(%{headers: headers}, name) when is_map(headers) and is_binary(name) do
    wanted = String.downcase(name)

    Enum.find_value(headers, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == wanted, do: value

      _ ->
        nil
    end)
  end

  def header(_ctx, _name), do: nil

  def timestamped(body, ctx, secret) do
    with signature when is_binary(signature) <- ctx[:signature],
         true <- String.valid?(signature),
         parts =
           signature
           |> String.split(",")
           |> Enum.map(&String.split(String.trim(&1), "=", parts: 2)),
         [timestamp] <- for(["t", value] <- parts, do: value),
         [_ | _] = signatures <- for(["v1", value] <- parts, do: value),
         true <-
           Enum.any?(
             signatures,
             &(hmac(timestamp <> "." <> body, &1, secret, :sha256, :hex) == :ok)
           ) do
      check_timestamp(timestamp, ctx, ctx[:replay_window_seconds] || 300)
    else
      _ -> {:error, :invalid_signature}
    end
  end

  def check_timestamp(timestamp, ctx, tolerance) when is_binary(timestamp) do
    with true <- String.valid?(timestamp) and Regex.match?(~r/\A[0-9]+\z/, timestamp),
         {seconds, ""} <- Integer.parse(timestamp),
         true <- is_integer(tolerance) and tolerance > 0 do
      now = div(ctx[:now_ms] || System.system_time(:millisecond), 1_000)
      if abs(now - seconds) <= tolerance, do: :ok, else: {:error, :stale_timestamp}
    else
      _ -> {:error, :invalid_signature}
    end
  end

  def check_timestamp(_timestamp, _ctx, _tolerance), do: {:error, :invalid_signature}

  def rsa_sha256(input, signature, pem) do
    with [entry] <- :public_key.pem_decode(pem),
         {:RSAPublicKey, _, _} = key <- :public_key.pem_entry_decode(entry),
         true <- :public_key.verify(input, :sha256, signature, key) do
      :ok
    else
      _ -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  end
end
