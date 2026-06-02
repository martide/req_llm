defmodule ReqLLM.Streaming.HTTP2ValidationTest do
  use ReqLLM.StreamingCase

  alias ReqLLM.Context
  alias ReqLLM.Streaming.FinchClient

  describe "HTTP/2 body size validation" do
    test "allows small request bodies with HTTP/2 pools" do
      configure_http2_pools!()

      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      small_prompt = "Hello, this is a small prompt"
      {:ok, context} = Context.normalize(small_prompt)

      result = start_mock_stream(model, context)

      assert {:ok, _task_pid, _http_context, _canonical_json} = result
    end

    test "blocks large request bodies (>64KB) with HTTP/2 pools" do
      configure_http2_pools!()

      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      large_prompt = String.duplicate("This is a large prompt. ", 3000)
      {:ok, context} = Context.normalize(large_prompt)

      result = start_mock_stream(model, context)

      assert {:error, {:provider_build_failed, {:http2_body_too_large, body_size, protocols}}} =
               result

      assert body_size > 65_535
      assert :http2 in protocols
    end

    test "allows large request bodies with HTTP/1-only pools (default)" do
      configure_http1_pools!()

      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      large_prompt = String.duplicate("This is a large prompt. ", 3000)
      {:ok, context} = Context.normalize(large_prompt)

      result = start_mock_stream(model, context)

      assert {:ok, _task_pid, _http_context, _canonical_json} = result
    end

    test "handles iodata request bodies (default_attach_stream providers) without raising" do
      # Providers that use default_attach_stream encode the body as iodata (an iolist),
      # not a binary. validate_http2_body_size must size the body with IO.iodata_length/1,
      # not byte_size/1 — byte_size/1 raises ArgumentError ("not a bitstring") on an iolist.
      configure_http1_pools!()

      System.put_env("CF_ACCOUNT_ID", "test-account")
      System.put_env("CLOUDFLARE_AI_GATEWAY_API_KEY", "test-key")

      on_exit(fn ->
        System.delete_env("CF_ACCOUNT_ID")
        System.delete_env("CLOUDFLARE_AI_GATEWAY_API_KEY")
      end)

      {:ok, model} = ReqLLM.model("cloudflare_ai_gateway:openai/gpt-4o")
      {:ok, context} = Context.normalize("Hello")

      result = start_mock_stream(ReqLLM.Providers.CloudflareAIGateway, model, context)

      assert {:ok, _task_pid, _http_context, _canonical_json} = result
    end

    test "error is caught by streaming module and logged" do
      configure_http2_pools!()

      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      large_prompt = String.duplicate("Large content ", 5000)
      {:ok, context} = Context.normalize(large_prompt)

      result = start_mock_stream(model, context)

      assert {:error, {:provider_build_failed, {:http2_body_too_large, _body_size, _protocols}}} =
               result
    end
  end

  defmodule MockStreamServer do
    use GenServer

    def start_link do
      GenServer.start_link(__MODULE__, [])
    end

    def init(_), do: {:ok, []}

    def handle_call({:http_event, _event}, _from, state) do
      {:reply, :ok, state}
    end
  end

  defp start_mock_stream(model, context),
    do: start_mock_stream(ReqLLM.Providers.OpenAI, model, context)

  defp start_mock_stream(provider, model, context) do
    {:ok, stream_server} = MockStreamServer.start_link()

    FinchClient.start_stream(
      provider,
      model,
      context,
      [],
      stream_server
    )
  end
end
