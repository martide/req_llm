defmodule ReqLLM.Coverage.CloudflareAIGateway.ComprehensiveTest do
  @moduledoc """
  Comprehensive coverage tests for the Cloudflare AI Gateway provider, generated
  by `ReqLLM.ProviderTest.Comprehensive`.

  Models are selected by `ModelMatrix` from the `:sample_text_models` config
  (curated to a couple of CF-proxied chat models), or overridden per-run via
  `REQ_LLM_MODELS` / `REQ_LLM_SAMPLE`.

  ## Running (replay, default)

      mix test test/coverage/cloudflare_ai_gateway/ --include coverage

  ## Recording fixtures against a live gateway

  Recording is one-shot — the account ID, gateway ID, and base URL are resolved
  from the environment. Authenticate with a Cloudflare API token that has the
  `AI Gateway` permission. `CF_GATEWAY_ID` is optional (omit to use the account's
  default gateway).

      CF_ACCOUNT_ID=your-id CF_GATEWAY_ID=your-gw \\
        CLOUDFLARE_AI_GATEWAY_API_KEY=your-cloudflare-api-token \\
        REQ_LLM_FIXTURES_MODE=record \\
        mix test test/coverage/cloudflare_ai_gateway/ --include coverage

  Limit which models are recorded with `REQ_LLM_MODELS`:

      REQ_LLM_MODELS="cloudflare_ai_gateway:openai/gpt-4o" CF_ACCOUNT_ID=... \\
        CLOUDFLARE_AI_GATEWAY_API_KEY=... REQ_LLM_FIXTURES_MODE=record \\
        mix test test/coverage/cloudflare_ai_gateway/ --include coverage

  > #### Account ID in fixtures {: .info}
  >
  > Your real Cloudflare account ID is written into the recorded request URL, the
  > same way Azure (resource name) and Vertex (project ID) fixtures work. It is not
  > a secret — the API token is the credential, and that is redacted automatically.
  """

  use ReqLLM.ProviderTest.Comprehensive, provider: :cloudflare_ai_gateway

  # The provider resolves base_url from CF_ACCOUNT_ID inside prepare_request, which
  # runs before the fixture step intercepts. A value must therefore be present even in
  # replay. In record mode the real env vars (passed on the command line) are used as-is;
  # in replay mode no network call happens, so inject deterministic placeholders.
  setup do
    if ReqLLM.Test.Env.fixtures_mode() == :replay do
      System.put_env("CF_ACCOUNT_ID", "test-account")
      System.put_env("CF_GATEWAY_ID", "test-gateway")

      on_exit(fn ->
        System.delete_env("CF_ACCOUNT_ID")
        System.delete_env("CF_GATEWAY_ID")
      end)
    end

    :ok
  end
end
