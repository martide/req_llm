defmodule ReqLLM.Providers.CloudflareAIGatewayTest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.CloudflareAIGateway

  alias ReqLLM.Providers.CloudflareAIGateway

  @cf_base "https://api.cloudflare.com/client/v4"

  def make_model do
    LLMDB.Model.new!(%{
      id: "openai/gpt-4o",
      provider: :cloudflare_ai_gateway,
      model: "openai/gpt-4o"
    })
  end

  describe "provider identity" do
    test "provider_id and default_env_key" do
      assert CloudflareAIGateway.provider_id() == :cloudflare_ai_gateway
      assert CloudflareAIGateway.default_env_key() == "CLOUDFLARE_AI_GATEWAY_API_KEY"
    end

    test "provider schema includes CF-specific options" do
      keys = CloudflareAIGateway.provider_schema().schema |> Keyword.keys()
      assert :cf_account_id in keys
      assert :cf_gateway_id in keys
      assert :cf_skip_cache in keys
      assert :cf_cache_ttl in keys
      assert :cf_metadata in keys
      assert :cf_collect_log in keys
    end

    test "cf_authorization is no longer a provider option" do
      keys = CloudflareAIGateway.provider_schema().schema |> Keyword.keys()
      refute :cf_authorization in keys
    end
  end

  # The REST API base URL is resolved in prepare_request/4 (before Options.process),
  # so URL construction is exercised there rather than in attach/3.
  describe "URL construction from provider_options" do
    test "builds REST API URL from cf_account_id in provider_options" do
      model = make_model()

      {:ok, request} =
        CloudflareAIGateway.prepare_request(:chat, model, "Hello",
          provider_options: [cf_account_id: "acc123"]
        )

      assert request.options[:base_url] == "#{@cf_base}/accounts/acc123/ai/v1"
    end

    test "appends /chat/completions to the resolved base URL" do
      model = make_model()

      {:ok, request} =
        CloudflareAIGateway.prepare_request(:chat, model, "Hello",
          provider_options: [cf_account_id: "acc123"]
        )

      assert request.url.path == "/chat/completions"
    end

    test "base_url option takes precedence over cf_account_id" do
      model = make_model()
      custom_url = "https://custom.gateway.example.com/v1"

      {:ok, request} =
        CloudflareAIGateway.prepare_request(:chat, model, "Hello",
          base_url: custom_url,
          provider_options: [cf_account_id: "acc123"]
        )

      assert request.options[:base_url] == custom_url
    end

    test "raises ReqLLM.Error.Invalid.Parameter when account_id is absent" do
      model = make_model()

      original_account = System.get_env("CF_ACCOUNT_ID")

      on_exit(fn ->
        if original_account,
          do: System.put_env("CF_ACCOUNT_ID", original_account),
          else: System.delete_env("CF_ACCOUNT_ID")
      end)

      System.delete_env("CF_ACCOUNT_ID")

      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        CloudflareAIGateway.prepare_request(:chat, model, "Hello", [])
      end
    end
  end

  describe "URL construction from environment variables" do
    test "falls back to CF_ACCOUNT_ID env var" do
      model = make_model()

      original_account = System.get_env("CF_ACCOUNT_ID")

      on_exit(fn ->
        if original_account,
          do: System.put_env("CF_ACCOUNT_ID", original_account),
          else: System.delete_env("CF_ACCOUNT_ID")
      end)

      System.put_env("CF_ACCOUNT_ID", "env-account")

      {:ok, request} = CloudflareAIGateway.prepare_request(:chat, model, "Hello", [])

      assert request.options[:base_url] == "#{@cf_base}/accounts/env-account/ai/v1"
    end

    test "provider_options cf_account_id takes precedence over env var" do
      model = make_model()

      original_account = System.get_env("CF_ACCOUNT_ID")

      on_exit(fn ->
        if original_account,
          do: System.put_env("CF_ACCOUNT_ID", original_account),
          else: System.delete_env("CF_ACCOUNT_ID")
      end)

      System.put_env("CF_ACCOUNT_ID", "env-account")

      {:ok, request} =
        CloudflareAIGateway.prepare_request(:chat, model, "Hello",
          provider_options: [cf_account_id: "opts-account"]
        )

      assert request.options[:base_url] == "#{@cf_base}/accounts/opts-account/ai/v1"
    end
  end

  describe "CF header injection" do
    def attach_with_headers(provider_opts) do
      model = make_model()

      Req.new()
      |> CloudflareAIGateway.attach(model, provider_options: provider_opts)
    end

    def get_header(request, name) do
      case request.headers do
        %{} = headers_map ->
          case Map.get(headers_map, name) do
            [value | _] -> value
            nil -> nil
          end

        headers_list when is_list(headers_list) ->
          case List.keyfind(headers_list, name, 0) do
            {^name, [value]} -> value
            {^name, value} when is_binary(value) -> value
            _ -> nil
          end
      end
    end

    test "cf_gateway_id sets the cf-aig-gateway-id header" do
      request = attach_with_headers(cf_gateway_id: "my-gateway")
      assert get_header(request, "cf-aig-gateway-id") == "my-gateway"
    end

    test "cf_skip_cache: true injects cf-aig-skip-cache: true header" do
      request = attach_with_headers(cf_skip_cache: true)
      assert get_header(request, "cf-aig-skip-cache") == "true"
    end

    test "cf_skip_cache: false injects cf-aig-skip-cache: false header" do
      request = attach_with_headers(cf_skip_cache: false)
      assert get_header(request, "cf-aig-skip-cache") == "false"
    end

    test "cf_skip_cache absent means header not set" do
      request = attach_with_headers([])
      assert get_header(request, "cf-aig-skip-cache") == nil
    end

    test "cf_cache_ttl injects cf-aig-cache-ttl as string" do
      request = attach_with_headers(cf_cache_ttl: 3600)
      assert get_header(request, "cf-aig-cache-ttl") == "3600"
    end

    test "cf_metadata is JSON-encoded into cf-aig-metadata header" do
      metadata = %{"user_id" => "u123", "session" => "s456"}
      request = attach_with_headers(cf_metadata: metadata)
      raw = get_header(request, "cf-aig-metadata")
      assert {:ok, ^metadata} = Jason.decode(raw)
    end

    test "cf_collect_log: true injects cf-aig-collect-log: true header" do
      request = attach_with_headers(cf_collect_log: true)
      assert get_header(request, "cf-aig-collect-log") == "true"
    end

    test "multiple CF headers can be set simultaneously" do
      request =
        attach_with_headers(
          cf_gateway_id: "gw",
          cf_skip_cache: true,
          cf_cache_ttl: 300,
          cf_collect_log: true
        )

      assert get_header(request, "cf-aig-gateway-id") == "gw"
      assert get_header(request, "cf-aig-skip-cache") == "true"
      assert get_header(request, "cf-aig-cache-ttl") == "300"
      assert get_header(request, "cf-aig-collect-log") == "true"
    end
  end
end
