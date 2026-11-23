# AzureVM Lua 5.1 service

AzureVM parses the binary chunk produced by `string.dump`, and its reader only
supports Lua 5.1 bytecode. This container runs the existing pipeline with a
native Lua 5.1 interpreter so it does not receive Lua 5.4 bytecode from
wasmoon.

Build from the repository root:

```sh
docker build -f services/azurevm-lua51/Dockerfile -t azurevm-lua51 .
```

Run it with a strong shared token:

```sh
docker run --rm -p 8080:8080 \
  -e AZUREVM_LUA51_SERVICE_TOKEN='replace-with-a-long-random-value' \
  azurevm-lua51
```

Configure the gateway with:

- `AZUREVM_LUA51_SERVICE_URL`: the service URL ending in `/obfuscate`
- `AZUREVM_LUA51_SERVICE_TOKEN`: the same shared token used by the container

The service accepts authenticated `POST /obfuscate` JSON requests with
`source`, optional `preset`, and optional integer `seed` fields. It responds
with `{ "output": "..." }`. `GET /health` reports the runtime version.
