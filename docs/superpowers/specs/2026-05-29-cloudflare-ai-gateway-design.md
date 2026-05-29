# Cloudflare AI Gateway Provider — Design Spec

**Date:** 2026-05-29  
**Status:** Approved

## Summary

Add `:cloudflare_ai_gateway` as a first-class provider in `req_llm`. It proxies requests through Cloudflare AI Gateway's OpenAI-compatible endpoint, enabling caching, rate limiting, logging, guardrails, and analytics without changing call sites beyond the provider identifier.

## Architecture

Single module `ReqLLM.Providers.CloudflareAIGateway` at `lib/req_llm/providers/cloudflare_ai_gateway.ex`.

Uses `use ReqLLM.Provider` + `use ReqLLM.Provider.Defaults` (same pattern as Groq, Zenmux, OpenRouter). Only `attach/3` is overridden to:
1. Construct the gateway base URL from `account_id` + `gateway_id`
2. Inject CF-specific request headers

**Wire format:** OpenAI Chat Completions, routed through CF's provider-native OpenAI path:
```
https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/openai
```

## URL Construction

Priority order (first match wins):

1. `base_url` option — full URL, used as-is (escape hatch)
2. `cf_account_id` + `cf_gateway_id` provider options → URL built dynamically
3. `CF_ACCOUNT_ID` + `CF_GATEWAY_ID` environment variables → URL built dynamically
4. Raises `ReqLLM.Error.Auth` with a clear message if neither account ID nor gateway ID can be resolved

## Authentication

**`CLOUDFLARE_AI_GATEWAY_API_KEY`** (or `api_key` option): the underlying provider's API key (OpenAI key, Anthropic key, etc.). CF forwards it as `Authorization: Bearer` to the target provider.

**Authenticated gateways:** If the CF gateway requires its own auth, set `cf_authorization` — this adds `cf-aig-authorization: Bearer <token>` alongside the underlying provider key.

## Provider Schema (CF-Specific Options)

| Option | Maps to header | Type | Notes |
|---|---|---|---|
| `cf_account_id` | URL path segment | `:string` | Required unless `base_url` provided |
| `cf_gateway_id` | URL path segment | `:string` | Required unless `base_url` provided |
| `cf_authorization` | `cf-aig-authorization` | `:string` | For authenticated gateways; prefixed with `Bearer ` automatically |
| `cf_skip_cache` | `cf-aig-skip-cache` | `:boolean` | Bypass response cache |
| `cf_cache_ttl` | `cf-aig-cache-ttl` | `:integer` | Cache TTL override in seconds |
| `cf_metadata` | `cf-aig-metadata` | `:map` | Custom metadata, up to 5 string/number/boolean pairs |
| `cf_collect_log` | `cf-aig-collect-log` | `:boolean` | Enable request/response log collection |

## Model Catalog

No `priv/models_local` entries. CF AI Gateway proxies models from many underlying providers; the relevant model catalog belongs to the underlying provider. Users reference models via explicit map specs or any string their gateway is configured to route:

```elixir
# Map spec (explicit)
{:ok, resp} = ReqLLM.generate_text(
  %{id: "gpt-4o", provider: :cloudflare_ai_gateway},
  "Hello",
  provider_options: [cf_account_id: "abc123", cf_gateway_id: "my-gw"]
)

# With env vars CF_ACCOUNT_ID + CF_GATEWAY_ID set
{:ok, resp} = ReqLLM.generate_text(
  %{id: "@cf/meta/llama-3.1-8b-instruct", provider: :cloudflare_ai_gateway},
  "Hello"
)
```

## Files

| File | Action | Purpose |
|---|---|---|
| `lib/req_llm/providers/cloudflare_ai_gateway.ex` | Create | Provider module |
| `guides/cloudflare_ai_gateway.md` | Create | User-facing guide |
| `test/providers/cloudflare_ai_gateway_test.exs` | Create | Unit tests |
| `test/coverage/cloudflare_ai_gateway_chat_test.exs` | Create | Coverage tests with fixtures |

## Testing Strategy

**Provider unit tests** (`test/providers/cloudflare_ai_gateway_test.exs`):
- URL is constructed correctly from `cf_account_id` + `cf_gateway_id` options
- URL falls back to env vars `CF_ACCOUNT_ID` + `CF_GATEWAY_ID`
- `base_url` option takes precedence over account/gateway IDs
- Missing account/gateway raises clear error
- CF headers injected correctly (`cf-aig-skip-cache`, `cf-aig-cache-ttl`, `cf-aig-metadata`, etc.)
- `cf_authorization` adds `cf-aig-authorization: Bearer <token>` header
- `cf_metadata` is JSON-encoded into the header

**Coverage tests** (`test/coverage/cloudflare_ai_gateway_chat_test.exs`):
- Basic text generation (fixture-backed)
- Streaming (fixture-backed)
- Record with `LIVE=true mix test --only provider:cloudflare_ai_gateway`

## Non-Goals

- Per-provider native format wrappers (Anthropic-native, Vertex-native through CF) — future work if needed
- CF model catalog / `mix mc` validation — not applicable without a fixed model list
- CF management API (create/delete gateways, fetch logs) — out of scope
