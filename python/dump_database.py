#!/usr/bin/env python3
"""Dump the complete COSMOS command & telemetry database over the HTTP API.

Walks every target -> every command and telemetry packet -> every
field, fetching the full metadata (bit_offset, bit_size, data_type,
endianness, array_size, states, units, ranges, defaults, descriptions,
limits, conversions, ...) and writes it all to one JSON file.

Requires a running CmdTlmServer (or Replay). Usage:

    python3 dump_database.py [output.json] [--host HOST] [--port PORT]
"""

import argparse
import json
import sys

from cosmos_api import CosmosApi, decode_raw


def dump(api):
    database = {"targets": {}}
    for target in api.call("get_target_list"):
        entry = {"commands": {}, "telemetry": {}}
        database["targets"][target] = entry

        for name, description in api.call("get_cmd_list", target):
            entry["commands"][name] = {
                "description": description,
                "parameters": decode_raw(api.call("get_cmd_details", target, name)),
            }

        for name, description in api.call("get_tlm_list", target):
            items = api.call("get_tlm_item_list", target, name)
            keys = [[target, name, item[0]] for item in items]
            details = decode_raw(api.call("get_tlm_details", keys)) if keys else []
            entry["telemetry"][name] = {
                "description": description,
                "items": details,
            }
    return database


def summarize(database):
    targets = database["targets"]
    n_cmd = sum(len(t["commands"]) for t in targets.values())
    n_cmd_params = sum(len(c["parameters"])
                       for t in targets.values() for c in t["commands"].values())
    n_tlm = sum(len(t["telemetry"]) for t in targets.values())
    n_tlm_items = sum(len(p["items"])
                      for t in targets.values() for p in t["telemetry"].values())
    print(f"targets: {len(targets)} ({', '.join(sorted(targets))})")
    print(f"commands: {n_cmd} packets, {n_cmd_params} parameters")
    print(f"telemetry: {n_tlm} packets, {n_tlm_items} items")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", default="cosmos_database.json")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=7777)
    args = parser.parse_args()

    api = CosmosApi(args.host, args.port)
    database = dump(api)
    with open(args.output, "w") as f:
        # Raw (non-UTF8) binary defaults decode to bytes; store them as hex
        json.dump(database, f, indent=1,
                  default=lambda o: o.hex() if isinstance(o, (bytes, bytearray))
                  else str(o))
    summarize(database)
    print(f"-> {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
