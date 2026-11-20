# Sig Demo for iPhone

Sig Demo is an experimental Signal-iOS client with an invite-only demo account and a Goose Development Kit agent. Type `@sig` and select Sig in the mention picker to ask a question. Reply to a message to ask about that specific text, or long-press a text message and choose **Fact check**.

Under **Settings → Sig agent**, choose on-device inference with Liquid LFM3 1.7B, ChatGPT, public Mesh, or paid Mesh. On-device inference uses the iPhone GPU through GDK, llama.cpp and Metal. The app can send public search terms to Brave when a lookup needs outside evidence and demo search access is configured. Ordinary local questions include up to ten recent eligible messages. Sig can request a wider window of up to 100 messages. A local question attached to a specific message uses that selected text.

The app uses its own bundle identifiers, storage and account. Installers need an invitation from the operator of the demo backend used to build their copy. The paid provider uses an embedded Lexe wallet.

## Build and source

- [Build an iPhone archive and configure your own demo service](sig-demo/ios/README.md)
- [iOS overlays and integration patches](sig-demo/ios)
- [Rust agent, inference provider and tools](sig-demo/gdk/native-agent)
- [Model, GDK and llama.cpp pins](sig-demo/ios/LocalModel/source.lock.json)
- [Free Mesh SDK pin](sig-demo/ios/Mesh/source.lock.json) and [paid Mesh source pin](sig-demo/ios/PaidMesh/source.lock.json)
- [Source provenance](SOURCE_PROVENANCE.json) and [licenses](LICENSES.md)
