# swift-mcp-kit

[![swift](https://img.shields.io/badge/swift-6.0-orange.svg)](https://swift.org)
[![platforms](https://img.shields.io/badge/platforms-macOS%2015%20%7C%20iOS%2017-lightgrey.svg)](#requirements)
[![license](https://img.shields.io/github/license/mgcrea/swift-mcp-kit.svg)](./LICENSE)

An [MCP](https://modelcontextprotocol.io) server that runs **inside** a Mac app, on the
loopback interface — so an agent can read what the app knows and ask it to do things,
without the app growing a backend.

It speaks the stateless `2026-07-28` revision **and** the two handshake-era revisions before
it, from one endpoint.

```swift
var tools = ToolTable()
tools.add(MCPTool(name: "list_sites", description: "Every site.", annotations: .readOnly)) { _ in
  .answer("3 sites", ["sites": [...]])
}

let listener = LoopbackListener(
  server: MCPServer(info: ServerInfo(name: "Almanac", version: "1.0.0"), tools: tools),
  gate: RequestGate(port: 8788, verify: tokenStore.verdict(for:)),
  allowWrites: { userDefaults.bool(forKey: "mcpAllowWrites") })

listener.start(port: 8788)
```

## Why dual-era, and why hand-rolled

The official [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) is at 0.12.1 and
implements `2025-11-25`; Swift was not among the Tier-1 SDKs (TypeScript, Python, Go, C#)
that shipped `2026-07-28`. So a Swift server that wants the current revision has to write it.

That is affordable because of what the revision *removed*. There is no `initialize`
handshake, no `Mcp-Session-Id`, no GET stream and no stream resumability — a server is one
`POST` endpoint and a pure function. `MCPKit` has no dependencies and no sockets, and the
whole conformance suite runs offline.

Speaking the older revisions too is not nostalgia. The `@modelcontextprotocol/sdk` in wide
use is 1.30.0, whose `LATEST_PROTOCOL_VERSION` is `2025-11-25`. A server that spoke only the
newest revision would be correct and unusable at the same time.

| | `2025-06-18` | `2025-11-25` | `2026-07-28` |
| --- | --- | --- | --- |
| Negotiation | `initialize` | `initialize` | `server/discover`, per-request `_meta` |
| Sessions | `Mcp-Session-Id` | `Mcp-Session-Id` | none |
| Result envelope | plain | plain | `resultType`, `ttlMs`, `cacheScope` |
| `structuredContent` | not read | read | read |

## Why this is not part of `swift-support-kit`

[`swift-support-kit`](https://github.com/mgcrea/swift-support-kit) **cannot open a
connection**, and that is a requirement rather than a coincidence: it is what keeps the
consuming apps' App Store privacy label at "Data Not Collected". This package binds a
listening socket, so it needs its own home rather than a version of that one which quietly
gained a network dependency. Same reasoning that produced
[`swift-cloudflare-kit`](https://github.com/mgcrea/swift-cloudflare-kit).

## The three products

| | |
| --- | --- |
| `MCPKit` | The protocol. Foundation only — no sockets, no SwiftUI. Every specification rule is a pure function over a frame, which is what lets the suite run offline on any platform. |
| `MCPKitLoopback` | The listener: a POSIX socket on `127.0.0.1`, a hand-written HTTP/1.1 parser, the `Host`/`Origin`/bearer checks, and the Keychain token. |
| `MCPKitUI` | The settings panel every consuming app otherwise builds again. |

## Security

The bind address is `127.0.0.1` and **is not configurable**. "Bind address" as a preference
is how `0.0.0.0` ends up in a support thread as a workaround. The port is a preference; the
interface is not.

Checks run in this order, and the order is the property rather than the tidiness:

1. **`Host` must be loopback.** This is what closes DNS rebinding, where a page the user
   visits resolves a name it controls to `127.0.0.1` and then talks to this server.
2. **`Origin`, if present, must be loopback.** Absent is allowed — real MCP clients are not
   browsers and send none, so requiring it would refuse every genuine caller.
3. **Then the bearer token**, compared in constant time.

Reversing 1 and 3 would turn the refusal into a measurement: a rebinding probe would learn
from the status code whether the token it guessed was valid.

Three further decisions worth knowing about:

- **A locked Keychain is `503`, never `401`.** "I cannot tell" is a different answer from
  "no", and collapsing them tells a correctly-configured user their credential is bad.
- **"No token" and "wrong token" get the identical sentence.** An error that distinguished
  them would confirm a guess was well-formed, which is halfway to right.
- **`GET` and `DELETE` on the endpoint answer `405`, not `404`.** A `404` sends an older
  client hunting for the deprecated HTTP+SSE endpoint instead of telling it the truth.

## The write gate

Tools declare a `ToolGate`, and with writes off a gated tool is **absent from `tools/list`**
rather than offered and refused — a model handed a tool it will always be refused for will
plan around it and then report a failure the person cannot act on. It is *also* refused at
call time, because `tools/list` is advisory: a client may hold a cached listing, or call a
name it guessed.

`ToolGate` is deliberately **not** the same thing as `readOnlyHint`. A tool that writes an
export file is honestly `readOnlyHint: false`, and putting a data-export feature behind a
safety switch would be the wrong reading of both. The gate governs changes to the user's
data, preferences and credentials.

## Requirements

macOS 15+ / iOS 17+, Swift 6. The floor is what the package needs — a BSD socket,
Foundation, and `Security` for the token — not what its consumers target.

## License

MIT
