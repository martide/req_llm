defmodule ReqLLM.Providers.CloudflareAIGatewayTest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.CloudflareAIGateway

  alias ReqLLM.Providers.CloudflareAIGateway

  @cf_base "https://gateway.ai.cloudflare.com/v1"

  def make_model do
    LLMDB.Model.new!(%{id: "gpt-4o", provider: :cloudflare_ai_gateway, model: "gpt-4o"})
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
      assert :cf_authorization in keys
      assert :cf_skip_cache in keys
      assert :cf_cache_ttl in keys
      assert :cf_metadata in keys
      assert :cf_collect_log in keys
    end
  end

  describe "URL construction from provider_options" do
    test "builds URL from cf_account_id + cf_gateway_id in provider_options" do
      model = make_model()

      request =
        Req.new()
        |> CloudflareAIGateway.attach(model,
          provider_options: [cf_account_id: "acc123", cf_gateway_id: "gw456"]
        )

      assert request.options[:base_url] == "#{@cf_base}/acc123/gw456/openai"
    end

    test "base_url option takes precedence over account/gateway IDs" do
      model = make_model()
      custom_url = "https://custom.gateway.example.com/v1"

      request =
        Req.new()
        |> CloudflareAIGateway.attach(model,
          base_url: custom_url,
          provider_options: [cf_account_id: "acc123", cf_gateway_id: "gw456"]
        )

      assert request.options[:base_url] == custom_url
    end

    test "raises ReqLLM.Error.Invalid.Parameter when account_id and gateway_id are absent" do
      model = make_model()

      original_account = System.get_env("CF_ACCOUNT_ID")
      original_gateway = System.get_env("CF_GATEWAY_ID")

      on_exit(fn ->
        if original_account, do: System.put_env("CF_ACCOUNT_ID", original_account),
          else: System.delete_env("CF_ACCOUNT_ID")
        if original_gateway, do: System.put_env("CF_GATEWAY_ID", original_gateway),
          else: System.delete_env("CF_GATEWAY_ID")
      end)

      System.delete_env("CF_ACCOUNT_ID")
      System.delete_env("CF_GATEWAY_ID")

      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        Req.new() |> CloudflareAIGateway.attach(model, [])
      end
    end
  end

  describe "URL construction from environment variables" do
    test "falls back to CF_ACCOUNT_ID + CF_GATEWAY_ID env vars" do
      model = make_model()

      original_account = System.get_env("CF_ACCOUNT_ID")
      original_gateway = System.get_env("CF_GATEWAY_ID")

      on_exit(fn ->
        if original_account, do: System.put_env("CF_ACCOUNT_ID", original_account),
          else: System.delete_env("CF_ACCOUNT_ID")
        if original_gateway, do: System.put_env("CF_GATEWAY_ID", original_gateway),
          else: System.delete_env("CF_GATEWAY_ID")
      end)

      System.put_env("CF_ACCOUNT_ID", "env-account")
      System.put_env("CF_GATEWAY_ID", "env-gateway")

      request =
        Req.new()
        |> CloudflareAIGateway.attach(model, [])

      assert request.options[:base_url] == "#{@cf_base}/env-account/env-gateway/openai"
    end

    test "provider_options take precedence over env vars" do
      model = make_model()

      original_account = System.get_env("CF_ACCOUNT_ID")
      original_gateway = System.get_env("CF_GATEWAY_ID")

      on_exit(fn ->
        if original_account, do: System.put_env("CF_ACCOUNT_ID", original_account),
          else: System.delete_env("CF_ACCOUNT_ID")
        if original_gateway, do: System.put_env("CF_GATEWAY_ID", original_gateway),
          else: System.delete_env("CF_GATEWAY_ID")
      end)

      System.put_env("CF_ACCOUNT_ID", "env-account")
      System.put_env("CF_GATEWAY_ID", "env-gateway")

      request =
        Req.new()
        |> CloudflareAIGateway.attach(model,
          provider_options: [cf_account_id: "opts-account", cf_gateway_id: "opts-gateway"]
        )

      assert request.options[:base_url] == "#{@cf_base}/opts-account/opts-gateway/openai"
    end
  end

  describe "CF header injection" do
    def attach_with_headers(provider_opts) do
      model = make_model()

      Req.new()
      |> CloudflareAIGateway.attach(model,
        provider_options: [cf_account_id: "acc", cf_gateway_id: "gw"] ++ provider_opts
      )
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

    test "cf_authorization gets Bearer prefix and sets cf-aig-authorization header" do
      request = attach_with_headers(cf_authorization: "my-cf-token")
      assert get_header(request, "cf-aig-authorization") == "Bearer my-cf-token"
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
      request = attach_with_headers(cf_skip_cache: true, cf_cache_ttl: 300, cf_collect_log: true)
      assert get_header(request, "cf-aig-skip-cache") == "true"
      assert get_header(request, "cf-aig-cache-ttl") == "300"
      assert get_header(request, "cf-aig-collect-log") == "true"
    end
  end
end
