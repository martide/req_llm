# Cloudflare AI Gateway

Cloudflare AI Gateway proxies LLM requests through Cloudflare's edge network, adding caching, rate limiting, logging, and observability to any OpenAI-compatible model.

This provider routes through the AI Gateway **REST API** endpoint — the supported replacement for the deprecated `/compat` gateway endpoint. It is OpenAI-shaped and can target any backend provider (OpenAI, Anthropic, Google, …) via the model field.

## Configuration

Authenticate with a Cloudflare API token that has the `AI Gateway` permission. Third-party models are billed via your Cloudflare account (Unified Billing) — no underlying provider API keys are sent.

```bash
# Your Cloudflare account ID (from the Cloudflare dashboard URL)
CF_ACCOUNT_ID=your-account-id

# Your AI Gateway ID (optional — omit to use the account's default gateway)
CF_GATEWAY_ID=your-gateway-id

# A Cloudflare API token with the AI Gateway permission
CLOUDFLARE_AI_GATEWAY_API_KEY=your-cloudflare-api-token
```

## Model Specs

Cloudflare AI Gateway has no model catalog — it proxies requests to underlying providers. Use the map form of model spec, and select the backend with the REST API's `author/model` convention:

```elixir
# Route to GPT-4o through your CF gateway
model = %{provider: :cloudflare_ai_gateway, model: "openai/gpt-4o"}

{:ok, response} = ReqLLM.generate_text(model, "Hello!")
```

The `model` field uses the `author/model` form the REST API expects:

```elixir
%{provider: :cloudflare_ai_gateway, model: "openai/gpt-4o"}
%{provider: :cloudflare_ai_gateway, model: "anthropic/claude-sonnet-4"}
%{provider: :cloudflare_ai_gateway, model: "google/gemini-3-flash"}
```

## URL Format

The gateway URL is constructed as:

```
https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1/chat/completions
```

The account ID lives in the URL path; the `/chat/completions` suffix is appended automatically. The gateway is selected via the `cf-aig-gateway-id` header (omit to use the account's default gateway).

## Basic Usage

```elixir
model = %{provider: :cloudflare_ai_gateway, model: "openai/gpt-4o"}

{:ok, response} = ReqLLM.generate_text(model, "Explain gravity in one sentence.")
IO.puts(ReqLLM.Response.text(response))
```

## Per-Call Provider Options

Override the account ID, gateway ID, or any CF header on a per-request basis via `provider_options`:

```elixir
{:ok, response} =
  ReqLLM.generate_text(
    %{provider: :cloudflare_ai_gateway, model: "openai/gpt-4o"},
    "Hello!",
    provider_options: [
      cf_account_id: "my-account",
      cf_gateway_id: "my-gateway"
    ]
  )
```

`cf_account_id` in `provider_options` takes precedence over the `CF_ACCOUNT_ID` environment variable. You can also pass `base_url` as a top-level option to `generate_text` to bypass URL construction entirely:

```elixir
{:ok, response} =
  ReqLLM.generate_text(
    %{provider: :cloudflare_ai_gateway, model: "openai/gpt-4o"},
    "Hello!",
    base_url: "https://api.cloudflare.com/client/v4/accounts/acc123/ai/v1"
  )
```

Note that `base_url` is a top-level option passed directly to `generate_text`, not inside `provider_options`.

## CF-Specific Headers

All CF-specific options are passed via `provider_options` and map to `cf-aig-*` request headers:

| Option | Header | Type | Description |
|---|---|---|---|
| `cf_gateway_id` | `cf-aig-gateway-id` | string | AI Gateway ID (omit to use the account's default gateway) |
| `cf_skip_cache` | `cf-aig-skip-cache` | boolean | Bypass the cached response for this request |
| `cf_cache_ttl` | `cf-aig-cache-ttl` | integer | Override cache TTL in seconds for this request |
| `cf_metadata` | `cf-aig-metadata` | map | Custom metadata attached to CF logs (up to 5 key-value pairs) |
| `cf_collect_log` | `cf-aig-collect-log` | boolean | Enable request/response log collection |

Example using multiple headers:

```elixir
{:ok, response} =
  ReqLLM.generate_text(
    %{provider: :cloudflare_ai_gateway, model: "openai/gpt-4o"},
    "Summarize the latest AI news.",
    provider_options: [
      cf_skip_cache: true,
      cf_cache_ttl: 3600,
      cf_metadata: %{"user_id" => "u123", "session_id" => "s456"},
      cf_collect_log: true
    ]
  )
```

## Streaming

Streaming works the same way as with any other provider:

```elixir
model = %{provider: :cloudflare_ai_gateway, model: "openai/gpt-4o"}

{:ok, stream} = ReqLLM.stream_text(model, "Tell me a short story.")

{:ok, response} = ReqLLM.StreamResponse.to_response(stream)
IO.puts(ReqLLM.Response.text(response))
```

For streaming with CF options:

```elixir
{:ok, stream} =
  ReqLLM.stream_text(
    model,
    "Tell me a short story.",
    provider_options: [cf_skip_cache: true, cf_collect_log: true]
  )
```

## Recording Fixtures for Tests

The coverage tests in `test/coverage/cloudflare_ai_gateway/` use recorded fixtures. To record new fixtures against a live gateway (authenticate with a Cloudflare API token that has the `AI Gateway` permission):

```bash
CF_ACCOUNT_ID=your-account-id \
CF_GATEWAY_ID=your-gateway-id \
CLOUDFLARE_AI_GATEWAY_API_KEY=your-cloudflare-api-token \
REQ_LLM_FIXTURES_MODE=record \
mix test test/coverage/cloudflare_ai_gateway/ --include coverage
```

This records HTTP interactions to `test/support/fixtures/cloudflare_ai_gateway/openai_gpt_4o/` and subsequent runs replay them without making API calls.

To replay existing fixtures (the default, no API key needed):

```bash
mix test test/coverage/cloudflare_ai_gateway/ --include coverage
```

## Resources

- [Cloudflare AI Gateway Documentation](https://developers.cloudflare.com/ai-gateway/)
- [AI Gateway Dashboard](https://dash.cloudflare.com/?to=/:account/ai/ai-gateway/general)
- [CF AI Gateway Caching](https://developers.cloudflare.com/ai-gateway/configuration/caching/)
- [CF AI Gateway Logging](https://developers.cloudflare.com/ai-gateway/observability/logging/)
