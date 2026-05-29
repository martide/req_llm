defmodule ReqLLM.Providers.CloudflareAIGateway do
  @moduledoc """
  Cloudflare AI Gateway provider — proxies LLM requests through CF AI Gateway's
  OpenAI-compatible endpoint, adding caching, logging, rate limiting, and guardrails.

  ## URL format

      https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/openai

  ## Configuration

  Set account ID and gateway ID via environment variables (recommended):

      export CF_ACCOUNT_ID=your-cloudflare-account-id
      export CF_GATEWAY_ID=your-gateway-id
      export CLOUDFLARE_AI_GATEWAY_API_KEY=your-underlying-provider-api-key

  Or pass per-call via provider_options:

      ReqLLM.generate_text(
        %{id: "gpt-4o", provider: :cloudflare_ai_gateway},
        "Hello",
        provider_options: [cf_account_id: "abc123", cf_gateway_id: "my-gw"]
      )

  ## CF-specific headers

  Pass via `provider_options`:

      provider_options: [
        cf_skip_cache: true,
        cf_cache_ttl: 3600,
        cf_metadata: %{"user_id" => "u1"},
        cf_collect_log: true,
        cf_authorization: "my-gateway-token"
      ]
  """

  use ReqLLM.Provider,
    id: :cloudflare_ai_gateway,
    default_base_url: "https://gateway.ai.cloudflare.com/v1",
    default_env_key: "CLOUDFLARE_AI_GATEWAY_API_KEY"

  @provider_schema [
    cf_account_id: [
      type: :string,
      doc: "Cloudflare account ID. Can also be set via CF_ACCOUNT_ID env var."
    ],
    cf_gateway_id: [
      type: :string,
      doc: "Cloudflare AI Gateway ID. Can also be set via CF_GATEWAY_ID env var."
    ],
    cf_authorization: [
      type: :string,
      doc:
        "Authorization token for authenticated CF gateways. Prefixed with 'Bearer ' automatically."
    ],
    cf_skip_cache: [
      type: :boolean,
      doc: "Skip the cached response for this request."
    ],
    cf_cache_ttl: [
      type: :integer,
      doc: "Override the cache TTL for this request, in seconds."
    ],
    cf_metadata: [
      type: :map,
      doc: "Custom metadata attached to this request in CF logs (up to 5 key-value pairs)."
    ],
    cf_collect_log: [
      type: :boolean,
      doc: "Enable request/response log collection for this request."
    ]
  ]

  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    provider_opts = Keyword.get(user_opts, :provider_options, [])
    base_url = resolve_base_url(user_opts, provider_opts)
    user_opts_with_url = Keyword.put(user_opts, :base_url, base_url)

    request
    |> then(
      &ReqLLM.Provider.Defaults.default_attach(__MODULE__, &1, model_input, user_opts_with_url)
    )
    |> inject_cf_headers(provider_opts)
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    provider_opts = Keyword.get(opts, :provider_options, [])
    base_url = resolve_base_url(opts, provider_opts)
    opts_with_url = Keyword.put(opts, :base_url, base_url)

    processed_opts =
      ReqLLM.Provider.Options.process_stream!(
        __MODULE__,
        opts[:operation] || :chat,
        model,
        context,
        opts_with_url
      )

    case ReqLLM.Provider.Defaults.default_attach_stream(
           __MODULE__,
           model,
           context,
           processed_opts,
           finch_name
         ) do
      {:ok, finch_req} ->
        cf_headers = build_cf_headers(provider_opts)
        # Finch.Request.headers is a plain list; appending here is the correct extension point
        {:ok, %{finch_req | headers: finch_req.headers ++ cf_headers}}

      error ->
        error
    end
  end

  defp resolve_base_url(opts, provider_opts) do
    account_from_opts = provider_opts[:cf_account_id]
    gateway_from_opts = provider_opts[:cf_gateway_id]

    cond do
      url = opts[:base_url] ->
        url

      account_from_opts && gateway_from_opts ->
        "#{default_base_url()}/#{account_from_opts}/#{gateway_from_opts}/openai"

      true ->
        account = System.get_env("CF_ACCOUNT_ID")
        gateway = System.get_env("CF_GATEWAY_ID")

        if account && gateway do
          "#{default_base_url()}/#{account}/#{gateway}/openai"
        else
          raise ReqLLM.Error.Invalid.Parameter.exception(
                  parameter:
                    "Cloudflare AI Gateway requires cf_account_id and cf_gateway_id. " <>
                      "Set CF_ACCOUNT_ID + CF_GATEWAY_ID env vars, " <>
                      "pass cf_account_id/cf_gateway_id in provider_options, " <>
                      "or pass base_url directly."
                )
        end
    end
  end

  defp inject_cf_headers(request, provider_opts) do
    Enum.reduce(build_cf_headers(provider_opts), request, fn {name, value}, req ->
      Req.Request.put_header(req, name, value)
    end)
  end

  defp build_cf_headers(provider_opts) do
    [
      {"cf-aig-authorization", cf_authorization(provider_opts[:cf_authorization])},
      {"cf-aig-skip-cache", to_string_value(provider_opts[:cf_skip_cache])},
      {"cf-aig-cache-ttl", to_string_value(provider_opts[:cf_cache_ttl])},
      {"cf-aig-metadata", encode_metadata(provider_opts[:cf_metadata])},
      {"cf-aig-collect-log", to_string_value(provider_opts[:cf_collect_log])}
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
  end

  defp cf_authorization(nil), do: nil
  defp cf_authorization(token), do: "Bearer #{token}"

  defp to_string_value(nil), do: nil
  defp to_string_value(true), do: "true"
  defp to_string_value(false), do: "false"
  defp to_string_value(n) when is_integer(n), do: Integer.to_string(n)

  defp encode_metadata(nil), do: nil
  defp encode_metadata(map) when is_map(map), do: Jason.encode!(map)
end
