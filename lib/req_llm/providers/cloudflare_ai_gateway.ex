defmodule ReqLLM.Providers.CloudflareAIGateway do
  @moduledoc """
  Cloudflare AI Gateway provider — proxies LLM requests through CF AI Gateway's
  OpenAI-compatible REST API, adding caching, logging, rate limiting, and guardrails.

  Routes through the REST API endpoint (the supported replacement for the
  deprecated `/compat` gateway endpoint), which is OpenAI-shaped and can target
  any backend provider (OpenAI, Anthropic, Google, …) via the model field.

  ## URL format

      https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1/chat/completions

  The account ID lives in the URL path; the gateway is selected via the
  `cf-aig-gateway-id` header (omit to use the account's default gateway).

  ## Configuration

  Authenticate with a Cloudflare API token that has the `AI Gateway` permission.
  Third-party models are billed via your Cloudflare account (Unified Billing) —
  no underlying provider API keys are sent.

      export CF_ACCOUNT_ID=your-cloudflare-account-id
      export CF_GATEWAY_ID=your-gateway-id            # optional, defaults to the account's default gateway
      export CLOUDFLARE_AI_GATEWAY_API_KEY=your-cloudflare-api-token

  Or pass per-call via `provider_options`:

      ReqLLM.generate_text(
        %{provider: :cloudflare_ai_gateway, model: "openai/gpt-4o"},
        "Hello",
        provider_options: [cf_account_id: "abc123", cf_gateway_id: "my-gw"]
      )

  ## Selecting a backend

  The backend is chosen by the model field, using the REST API's `author/model`
  convention:

      %{provider: :cloudflare_ai_gateway, model: "openai/gpt-4o"}
      %{provider: :cloudflare_ai_gateway, model: "anthropic/claude-sonnet-4"}
      %{provider: :cloudflare_ai_gateway, model: "google/gemini-3-flash"}

  ## CF-specific headers

  Pass via `provider_options`:

      provider_options: [
        cf_skip_cache: true,
        cf_cache_ttl: 3600,
        cf_metadata: %{"user_id" => "u1"},
        cf_collect_log: true
      ]
  """

  use ReqLLM.Provider,
    id: :cloudflare_ai_gateway,
    default_base_url: "https://api.cloudflare.com/client/v4",
    default_env_key: "CLOUDFLARE_AI_GATEWAY_API_KEY"

  @provider_schema [
    cf_account_id: [
      type: :string,
      doc: "Cloudflare account ID. Can also be set via CF_ACCOUNT_ID env var."
    ],
    cf_gateway_id: [
      type: :string,
      doc:
        "AI Gateway ID, sent as the cf-aig-gateway-id header. Can also be set via " <>
          "CF_GATEWAY_ID env var. Omit to use the account's default gateway."
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
  def prepare_request(operation, model_input, input, opts) do
    # Resolve base_url BEFORE Options.process so its put_new_lazy won't inject the
    # placeholder default_base_url/0 (which lacks the account path). This mirrors the
    # convention used by the built-in dynamic-URL providers (Azure, Vertex, Bedrock).
    opts =
      Keyword.put_new_lazy(opts, :base_url, fn ->
        resolve_base_url(Keyword.get(opts, :provider_options, []))
      end)

    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_input, input, opts)
  end

  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    # base_url is already resolved in prepare_request and carried through opts.
    request
    |> then(&ReqLLM.Provider.Defaults.default_attach(__MODULE__, &1, model_input, user_opts))
    |> inject_cf_headers(Keyword.get(user_opts, :provider_options, []))
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    provider_opts = Keyword.get(opts, :provider_options, [])

    opts =
      opts
      |> Keyword.put_new_lazy(:base_url, fn -> resolve_base_url(provider_opts) end)
      |> put_cf_headers(provider_opts)

    processed_opts =
      ReqLLM.Provider.Options.process_stream!(
        __MODULE__,
        opts[:operation] || :chat,
        model,
        context,
        opts
      )

    # cf-aig-* headers were merged into req_http_options above, so default_attach_stream
    # builds the Finch request with them already included.
    ReqLLM.Provider.Defaults.default_attach_stream(
      __MODULE__,
      model,
      context,
      processed_opts,
      finch_name
    )
  end

  @impl ReqLLM.Provider
  def build_body(request) do
    request
    |> ReqLLM.Provider.Defaults.default_build_body()
    |> normalize_tool_choice()
  end

  # The default body encoder passes tool_choice through verbatim, but the REST API's
  # OpenAI-compatible endpoint expects OpenAI's forced-tool shape. Translate ReqLLM's
  # canonical %{type: "tool", name: name} form accordingly; anything already valid
  # ("auto", "required", %{type: "function", ...}) passes through untouched.
  defp normalize_tool_choice(%{tool_choice: %{type: "tool", name: name}} = body)
       when is_binary(name),
       do: %{body | tool_choice: %{type: "function", function: %{name: name}}}

  defp normalize_tool_choice(%{tool_choice: %{"type" => "tool", "name" => name}} = body)
       when is_binary(name),
       do: %{body | tool_choice: %{"type" => "function", "function" => %{"name" => name}}}

  defp normalize_tool_choice(body), do: body

  # Builds the REST API base URL from the account ID. The default `prepare_request`
  # appends "/chat/completions", yielding `.../accounts/{account}/ai/v1/chat/completions`.
  defp resolve_base_url(provider_opts) do
    case provider_opts[:cf_account_id] || System.get_env("CF_ACCOUNT_ID") do
      account when is_binary(account) ->
        "#{default_base_url()}/accounts/#{account}/ai/v1"

      _ ->
        raise ReqLLM.Error.Invalid.Parameter.exception(
                parameter:
                  "Cloudflare AI Gateway requires a Cloudflare account ID. " <>
                    "Set CF_ACCOUNT_ID env var, pass cf_account_id in provider_options, " <>
                    "or pass base_url directly."
              )
    end
  end

  # Merge cf-aig-* headers into req_http_options so default_attach_stream picks them up.
  defp put_cf_headers(opts, provider_opts) do
    cf_headers = build_cf_headers(provider_opts)

    Keyword.update(opts, :req_http_options, [headers: cf_headers], fn http_opts ->
      Keyword.update(http_opts, :headers, cf_headers, &(&1 ++ cf_headers))
    end)
  end

  defp inject_cf_headers(request, provider_opts) do
    Enum.reduce(build_cf_headers(provider_opts), request, fn {name, value}, req ->
      Req.Request.put_header(req, name, value)
    end)
  end

  defp build_cf_headers(provider_opts) do
    [
      {"cf-aig-gateway-id", provider_opts[:cf_gateway_id] || System.get_env("CF_GATEWAY_ID")},
      {"cf-aig-skip-cache", to_string_value(provider_opts[:cf_skip_cache])},
      {"cf-aig-cache-ttl", to_string_value(provider_opts[:cf_cache_ttl])},
      {"cf-aig-metadata", encode_metadata(provider_opts[:cf_metadata])},
      {"cf-aig-collect-log", to_string_value(provider_opts[:cf_collect_log])}
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
  end

  defp to_string_value(nil), do: nil
  defp to_string_value(true), do: "true"
  defp to_string_value(false), do: "false"
  defp to_string_value(n) when is_integer(n), do: Integer.to_string(n)

  defp encode_metadata(nil), do: nil
  defp encode_metadata(map) when is_map(map), do: Jason.encode!(map)
end
