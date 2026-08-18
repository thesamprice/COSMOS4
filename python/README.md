# Python access to the COSMOS 4 API

COSMOS's CmdTlmServer (and Replay) serve a JSON-RPC 2.0 HTTP API — the
same one every COSMOS tool uses internally. This directory verifies it
end to end from Python and provides a dependency-free client.

Two ways in:

1. **The official client**: `pip install ballcosmos` (verified working
   against this modernized COSMOS — see `verify_api.py`'s cross-check).
   **Note**: stock ballcosmos corrupts binary parameters (bytes >= 0x80
   get re-encoded as UTF-8 on the wire) and lacks `get_cmd_details`.
   Both are fixed on the fork:
   `pip install git+https://github.com/thesamprice/python-ballcosmos@get-cmd-details-and-binary-fix`
2. **`cosmos_api.py`** (here): a stdlib-only clone of its core. One
   class, one method: `CosmosApi().call(method, *params)`.

Authentication: the server checks the `Host` header against
`System.allowed_hosts` (default `127.0.0.1:7777`) and `X-Csrf-Token`
against the system config's `X_CSRF_TOKEN` (the demo ships
`SuperSecret`; override with the `COSMOS_X_CSRF_TOKEN` environment
variable — ballcosmos reads the same variable).

## Quick start

```sh
# 1. Start a headless demo server
env COSMOS_USERPATH=$(pwd)/demo bundle exec ruby python/run_demo_server.rb &

# 2. Verify everything (15 checks incl. a ballcosmos cross-check)
python3 python/verify_api.py

# 3. Dump the complete cmd/tlm database to JSON
python3 python/dump_database.py cosmos_database.json
```

## Full-database introspection

Every field's position and metadata is queryable:

- `get_target_list` → all targets
- `get_tlm_list(target)` / `get_tlm_item_list(target, packet)` →
  telemetry packets and items
- `get_tlm_details([[tgt, pkt, item], ...])` → the **complete**
  item hash: `bit_offset`, `bit_size`, `data_type`, `endianness`,
  `array_size`, `default`, `states`, `range`, `units`, `limits`,
  `format_string`, conversions, `description`, `meta`, ...
- `get_cmd_list(target)` → command packets
- `get_cmd_details(target, command)` → the same complete hash for
  every command parameter (this method was added during the
  modernization; `get_cmd_param_list` predates it but omits offsets)
- Plus the whole script API: `tlm`, `get_tlm_values`, `cmd`, limits,
  interfaces, etc.

`dump_database.py` walks all of it into one JSON file (~490 KB for the
demo config: 6 targets, 29 command packets / 223 parameters, 15
telemetry packets / 340 items, every field with its full metadata).
