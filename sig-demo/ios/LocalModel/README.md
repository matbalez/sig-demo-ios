# On-device local inference

Sig’s iPhone development build bundles LiquidAI LFM3-1.7B Q4_K_M (1,099,627,808 bytes). The exact revision, file size and SHA-256 are in [source.lock.json](source.lock.json). The weights ship with the [LFM Open License](Licenses/LFM-Open-License.txt).

The Rust agent uses `goose-local-inference` to run llama.cpp in the app process. The model uses the iPhone GPU through Metal. The GDK runs the model’s structured tool calls and feeds their results back into the next turn. A web search sends its query to Brave.

Ordinary prompts include up to ten recent eligible messages. A reply to a selected message focuses on its quoted text. The model can call `read_chat_history` for up to 100 eligible messages when a request needs more context. Per-chat sessions share an account-scoped model instance. Changing provider or account, or moving the app into the background, cancels native work before releasing the engine.

Prepare and verify the model with

```sh
python3 sig-demo/ios/LocalModel/prepare.py --root .sig-demo/ios/local-model-work --models-only
```

The iPhone app links the release arm64 Rust archive, its llama.cpp Metal backend and matching UniFFI bindings. [Build the iPhone app](../README.md).
