# Cloudflare AI Gateway

Cloudflare AI Gateway proxies LLM requests through Cloudflare's edge network, adding caching, rate limiting, logging, and observability to any OpenAI-compatible model.

## Configuration

Cloudflare AI Gateway requires three environment variables:

```bash
# Your Cloudflare account ID (from the Cloudflare dashboard URL)
CF_ACCOUNT_ID=your-account-id

# Your AI Gateway ID (created in AI > AI Gateway in the dashboard)
CF_GATEWAY_ID=your-gateway-id

# The API key for the underlying model provider (e.g. OpenAI, Groq)
CLOUDFLARE_AI_GATEWAY_API_KEY=your-underlying-provider-api-key
```

## Model Specs

Cloudflare AI Gateway has no model catalog — it proxies requests to underlying providers. Use the map form of model spec with the model ID that your gateway's underlying provider expects:

```elixir
# Route to GPT-4o through your CF gateway
model = %{id: "gpt-4o", provider: :cloudflare_ai_gateway, model: "gpt-4o"}

{:ok, response} = ReqLLM.generate_text(model, "Hello!")
```

The `model` key in the map must match the model ID the underlying provider accepts (e.g. `"gpt-4o"`, `"llama-3.1-8b-instant"`, `"claude-3-5-sonnet-20241022"`).

## URL Format

The gateway URL is constructed as:

```
https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/openai
```

The `/openai` suffix is appended automatically. All requests use the OpenAI-compatible chat completions endpoint.

## Basic Usage

```elixir
model = %{id: "gpt-4o", provider: :cloudflare_ai_gateway, model: "gpt-4o"}

{:ok, response} = ReqLLM.generate_text(model, "Explain gravity in one sentence.")
IO.puts(ReqLLM.Response.text(response))
```

## Per-Call Provider Options

Override the account ID, gateway ID, or any CF header on a per-request basis via `provider_options`:

```elixir
{:ok, response} =
  ReqLLM.generate_text(
    %{id: "gpt-4o", provider: :cloudflare_ai_gateway, model: "gpt-4o"},
    "Hello!",
    provider_options: [
      cf_account_id: "my-account",
      cf_gateway_id: "my-gateway"
    ]
  )
```

`cf_account_id` and `cf_gateway_id` in `provider_options` take precedence over environment variables. You can also pass `base_url` directly to bypass URL construction entirely:

```elixir
provider_options: [],
base_url: "https://gateway.ai.cloudflare.com/v1/acct123/gw456/openai"
```

## Authenticated Gateways

If your gateway requires a gateway-level authentication token (separate from the underlying model API key), pass it via `cf_authorization`:

```elixir
{:ok, response} =
  ReqLLM.generate_text(
    model,
    "Hello!",
    provider_options: [cf_authorization: "my-gateway-token"]
  )
```

The token is sent as `cf-aig-authorization: Bearer my-gateway-token`.

## CF-Specific Headers

All CF-specific options are passed via `provider_options` and map to `cf-aig-*` request headers:

| Option | Header | Type | Description |
|---|---|---|---|
| `cf_skip_cache` | `cf-aig-skip-cache` | boolean | Bypass the cached response for this request |
| `cf_cache_ttl` | `cf-aig-cache-ttl` | integer | Override cache TTL in seconds for this request |
| `cf_metadata` | `cf-aig-metadata` | map | Custom metadata attached to CF logs (up to 5 key-value pairs) |
| `cf_collect_log` | `cf-aig-collect-log` | boolean | Enable request/response log collection |
| `cf_authorization` | `cf-aig-authorization` | string | Gateway authentication token (prefixed with `Bearer ` automatically) |

Example using multiple headers:

```elixir
{:ok, response} =
  ReqLLM.generate_text(
    %{id: "gpt-4o", provider: :cloudflare_ai_gateway, model: "gpt-4o"},
    "Summarize the latest AI news.",
    provider_options: [
      cf_skip_cache: true,
      cf_cache_ttl: 3600,
      cf_metadata: %{"user_id" => "u123", "session_id" => "s456"},
      cf_collect_log: true,
      cf_authorization: "my-gateway-token"
    ]
  )
```

## Streaming

Streaming works the same way as with any other provider:

```elixir
model = %{id: "gpt-4o", provider: :cloudflare_ai_gateway, model: "gpt-4o"}

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

The coverage tests in `test/coverage/cloudflare_ai_gateway/` use recorded fixtures. To record new fixtures against a live gateway:

```bash
CF_ACCOUNT_ID=your-account-id \
CF_GATEWAY_ID=your-gateway-id \
CLOUDFLARE_AI_GATEWAY_API_KEY=your-openai-key \
REQ_LLM_FIXTURES_MODE=record \
mix test test/coverage/cloudflare_ai_gateway/ --include coverage
```

This records HTTP interactions to `test/support/fixtures/cloudflare_ai_gateway/gpt_4o/` and subsequent runs replay them without making API calls.

To replay existing fixtures (the default, no API key needed):

```bash
mix test test/coverage/cloudflare_ai_gateway/ --include coverage
```

## Resources

- [Cloudflare AI Gateway Documentation](https://developers.cloudflare.com/ai-gateway/)
- [AI Gateway Dashboard](https://dash.cloudflare.com/?to=/:account/ai/ai-gateway/general)
- [CF AI Gateway Caching](https://developers.cloudflare.com/ai-gateway/configuration/caching/)
- [CF AI Gateway Logging](https://developers.cloudflare.com/ai-gateway/observability/logging/)
