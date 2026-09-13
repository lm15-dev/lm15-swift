# Provider declarations

Pinned to `CONTRACT_PIN`. Capability policies, not this table, decide whether a particular operation can be sent. Passing the corpus is not live provider certification.

| Provider | Swift constructor | Dialect | Environment keys |
|---|---|---|---|
| openai | `OpenAILM` | openai-responses | `OPENAI_API_KEY` |
| openai-chat | `OpenAIChatLM` | openai-chat | `OPENAI_API_KEY` |
| anthropic | `AnthropicLM` | anthropic | `ANTHROPIC_API_KEY` |
| gemini | `GeminiLM` | gemini | `GEMINI_API_KEY`, `GOOGLE_API_KEY` |
| xai | `XaiLM` | openai-chat | `XAI_API_KEY` |
| claude-code | `ClaudeCodeLM` | anthropic |  |
| openai-codex | `OpenAICodexLM` | openai-responses |  |
| groq | `GroqLM` | openai-chat | `GROQ_API_KEY` |
| openrouter | `OpenRouterLM` | openai-chat | `OPENROUTER_API_KEY` |
| deepseek | `DeepSeekLM` | openai-chat | `DEEPSEEK_API_KEY` |
| deepseek-anthropic | `DeepSeekAnthropicLM` | anthropic | `DEEPSEEK_API_KEY` |
| zai | `ZaiLM` | openai-chat | `ZAI_API_KEY` |
| moonshotai | `MoonshotAILM` | openai-chat | `MOONSHOTAI_API_KEY`, `MOONSHOT_API_KEY` |
| moonshotai-responses | `MoonshotAIResponsesLM` | openai-responses | `MOONSHOTAI_API_KEY`, `MOONSHOT_API_KEY` |
| moonshotai-anthropic | `MoonshotAIAnthropicLM` | anthropic | `MOONSHOTAI_API_KEY`, `MOONSHOT_API_KEY` |
| meta | `MetaLM` | openai-responses | `META_API_KEY` |
| meta-chat | `MetaChatLM` | openai-chat | `META_API_KEY` |
| meta-anthropic | `MetaAnthropicLM` | anthropic | `META_API_KEY` |
| azure | `AzureLM` | openai-responses | `AZURE_OPENAI_API_KEY` |
| azure-chat | `AzureChatLM` | openai-chat | `AZURE_OPENAI_API_KEY` |
| azure-anthropic | `AzureAnthropicLM` | anthropic | `ANTHROPIC_FOUNDRY_API_KEY` |
| aws-anthropic | `AWSAnthropicLM` | anthropic | `ANTHROPIC_AWS_API_KEY` |
| bedrock-anthropic | `BedrockAnthropicLM` | anthropic | `AWS_BEARER_TOKEN_BEDROCK` |
| bedrock-chat | `BedrockChatLM` | openai-chat | `AWS_BEARER_TOKEN_BEDROCK` |
| bedrock-mantle-chat | `BedrockMantleChatLM` | openai-chat | `AWS_BEARER_TOKEN_BEDROCK` |
| vertex | `VertexLM` | gemini |  |
| vertex-express | `VertexExpressLM` | gemini | `GOOGLE_API_KEY` |
| vertex-anthropic | `VertexAnthropicLM` | anthropic |  |
| ollama | `OllamaLM` | openai-chat |  |
| vllm | `VllmLM` | openai-chat |  |
| sglang | `SglangLM` | openai-chat |  |
