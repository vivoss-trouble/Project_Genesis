# Genesis MobileControl Profile

`MobileControl` is the first mobile target profile. It is intentionally not a
full local Genesis node.

## Allowed

- read node health from a remote Genesis node
- trigger remote jobs
- view job status
- download or page through evidence
- keep a local read-only evidence cache
- send request/response payloads through SDK `RemoteHttp` IPC

## Forbidden

- local native plugins
- local Java probe
- local browser automation
- local subprocess workers
- full release gate execution
- assuming background execution survives OS suspension

## Reason

iOS and Android sandboxing, background limits, JIT restrictions, and app-store
runtime policies make full desktop parity the wrong first target. The mobile
product should be a controller and evidence viewer first. A future
`MobileLocalLight` profile can add carefully bounded local Wasm validation after
mobile Wasm execution is separately certified.

## Current Adapter Path

`MobileControlAdapter` rejects local service IPC and local workers, but accepts
`IpcEndpoint::RemoteHttp` through the shared platform HTTP transport. This keeps the
mobile shell as a thin controller: it depends on `GenesisSdk` and a remote node URL, not
on Unix sockets, Windows named pipes, local daemons, or native plugins.
