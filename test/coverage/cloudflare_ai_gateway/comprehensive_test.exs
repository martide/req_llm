defmodule ReqLLM.Coverage.CloudflareAIGateway.ComprehensiveTest do
  @moduledoc """
  Fixture-backed coverage tests for the Cloudflare AI Gateway provider.

  These tests verify that the provider correctly builds requests, injects
  CF-specific headers, and parses OpenAI-compatible responses.

  ## Running

  Tests are tagged `:coverage` and excluded by default. To run:

      mix test test/coverage/cloudflare_ai_gateway/ --include coverage

  ## Recording fixtures against a live gateway

      CF_ACCOUNT_ID=your-id CF_GATEWAY_ID=your-gw \\
        CLOUDFLARE_AI_GATEWAY_API_KEY=your-openai-key \\
        REQ_LLM_FIXTURES_MODE=record \\
        mix test test/coverage/cloudflare_ai_gateway/ --include coverage
  """

  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "cloudflare_ai_gateway"
  @moduletag timeout: 60_000

  @cf_base "https://gateway.ai.cloudflare.com/v1"
  @test_account "test-account"
  @test_gateway "test-gateway"

  setup do
    # Ensure env vars are present for URL construction (not needed during fixture
    # replay since base_url is passed directly, but needed for RECORD mode)
    System.put_env("CF_ACCOUNT_ID", @test_account)
    System.put_env("CF_GATEWAY_ID", @test_gateway)

    on_exit(fn ->
      System.delete_env("CF_ACCOUNT_ID")
      System.delete_env("CF_GATEWAY_ID")
    end)

    model =
      LLMDB.Model.new!(%{
        id: "gpt-4o",
        provider: :cloudflare_ai_gateway,
        model: "gpt-4o"
      })

    {:ok, model: model}
  end

  describe "gpt-4o via Cloudflare AI Gateway" do
    @tag scenario: :basic
    test "basic generate_text (non-streaming)", %{model: model} do
      opts = [
        fixture: "basic",
        base_url: "#{@cf_base}/#{@test_account}/#{@test_gateway}/openai",
        temperature: 0.0,
        max_tokens: 50,
        seed: 42
      ]

      ReqLLM.generate_text(model, "Hello world!", opts)
      |> assert_basic_response()
    end

    @tag scenario: :streaming
    test "stream_text (streaming)", %{model: model} do
      context =
        ReqLLM.Context.new([
          ReqLLM.Context.system("You are a helpful, creative assistant."),
          ReqLLM.Context.user("Say hello in one short, imaginative sentence.")
        ])

      opts = [
        fixture: "streaming",
        base_url: "#{@cf_base}/#{@test_account}/#{@test_gateway}/openai",
        temperature: 0.9,
        max_tokens: 100,
        top_p: 0.8
      ]

      {:ok, stream_response} = ReqLLM.stream_text(model, context, opts)

      assert %ReqLLM.StreamResponse{} = stream_response
      assert stream_response.stream
      assert stream_response.metadata_handle

      {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

      assert %ReqLLM.Response{} = response
      assert response.message.role == :assistant

      text = ReqLLM.Response.text(response) || ""
      assert text != "", "Expected non-empty streaming text"

      finish_reason = ReqLLM.StreamResponse.finish_reason(stream_response)
      refute is_nil(finish_reason)
    end
  end
end
