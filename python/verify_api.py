#!/usr/bin/env python3
"""Verify the COSMOS HTTP API exposes the full cmd/tlm database to Python.

Asserts, against a running CmdTlmServer with the demo configuration:
- every target, command packet, and telemetry packet is listed
- every command parameter and telemetry item returns full metadata
  (name, bit_offset, bit_size, data_type present on every field)
- offsets/metadata spot-check against known demo definitions
- live value reads work (tlm / get_tlm_values)
- the official `ballcosmos` client (if installed) agrees with the
  stdlib client

Exits 0 on success; prints "VERIFY_API OK".
"""

import sys

from cosmos_api import CosmosApi, decode_raw

checks = 0


def check(name, condition):
    global checks
    if not condition:
        raise SystemExit(f"FAILED: {name}")
    checks += 1
    print(f"ok: {name}")


def main():
    api = CosmosApi()

    targets = api.call("get_target_list")
    check(f"targets listed ({targets})",
          {"INST", "INST2", "SYSTEM"} <= set(targets))

    # --- Full-coverage walk: every field of every packet has offsets ---
    required = {"name", "bit_offset", "bit_size", "data_type"}
    cmd_packets = tlm_packets = cmd_params = tlm_items = 0
    for target in targets:
        for name, _desc in api.call("get_cmd_list", target):
            cmd_packets += 1
            details = decode_raw(api.call("get_cmd_details", target, name))
            for param in details:
                missing = required - set(param)
                if missing:
                    raise SystemExit(
                        f"FAILED: {target} {name} {param.get('name')} missing {missing}")
            cmd_params += len(details)
        for name, _desc in api.call("get_tlm_list", target):
            tlm_packets += 1
            items = api.call("get_tlm_item_list", target, name)
            keys = [[target, name, item[0]] for item in items]
            details = decode_raw(api.call("get_tlm_details", keys)) if keys else []
            for item in details:
                missing = required - set(item)
                if missing:
                    raise SystemExit(
                        f"FAILED: {target} {name} {item.get('name')} missing {missing}")
            tlm_items += len(details)
    check(f"all command params carry offsets+metadata "
          f"({cmd_packets} packets, {cmd_params} params)", cmd_params > 50)
    check(f"all telemetry items carry offsets+metadata "
          f"({tlm_packets} packets, {tlm_items} items)", tlm_items > 300)

    # --- Spot checks against the demo INST definitions ---
    [temp1] = decode_raw(api.call(
        "get_tlm_details", [["INST", "HEALTH_STATUS", "TEMP1"]]))
    check(f"TEMP1 offset/size/type "
          f"({temp1['bit_offset']}/{temp1['bit_size']}/{temp1['data_type']})",
          temp1["bit_size"] == 16 and temp1["data_type"] == "UINT"
          and temp1["bit_offset"] > 0)
    check("TEMP1 limits metadata present", "limits" in temp1)
    check("TEMP1 units", temp1.get("units") == "C")

    collect = {p["name"]: p
               for p in decode_raw(api.call("get_cmd_details", "INST", "COLLECT"))}
    check(f"COLLECT params ({sorted(collect)})",
          {"TYPE", "DURATION", "OPCODE", "TEMP"} <= set(collect))
    type_param = collect["TYPE"]
    check(f"COLLECT TYPE offset/size/states "
          f"({type_param['bit_offset']}/{type_param['bit_size']})",
          type_param["bit_offset"] == 64 and type_param["bit_size"] == 16
          and type_param["states"] == {"NORMAL": 0, "SPECIAL": 1})
    check("COLLECT TYPE required flag", type_param["required"] is True)
    check(f"COLLECT OPCODE default 0x{collect['OPCODE']['default']:X}",
          collect["OPCODE"]["default"] == 0xAB)

    # Offsets are internally consistent: CCSDS header then params in order
    ordered = sorted(collect.values(), key=lambda p: p["bit_offset"])
    check("COLLECT param offsets strictly increasing",
          all(a["bit_offset"] < b["bit_offset"]
              for a, b in zip(ordered, ordered[1:])))

    # --- Live values over the same API ---
    count = api.call("tlm", "INST HEALTH_STATUS RECEIVED_COUNT")
    check(f"live tlm read (RECEIVED_COUNT={count})", isinstance(count, (int, float)))
    values = api.call("get_tlm_values",
                      [["INST", "HEALTH_STATUS", "TEMP1"],
                       ["INST", "HEALTH_STATUS", "TEMP2"]])
    check("get_tlm_values shape", len(values) == 4 and len(values[0]) == 2)

    # --- Cross-check with the official ballcosmos client if available ---
    # ballcosmos reads COSMOS_X_CSRF_TOKEN (and host/port) from the
    # environment at import time, so it must be set before the import.
    import os
    os.environ.setdefault("COSMOS_X_CSRF_TOKEN", api.x_csrf_token)
    try:
        import ballcosmos
    except ImportError:
        print("skip: ballcosmos not installed")
    else:
        bc_targets = ballcosmos.get_target_list()
        check("ballcosmos client agrees on targets",
              list(bc_targets) == list(targets))
        bc_temp1 = ballcosmos.get_tlm_details(
            [["INST", "HEALTH_STATUS", "TEMP1"]])[0]
        check("ballcosmos client agrees on TEMP1 metadata",
              bc_temp1["bit_offset"] == temp1["bit_offset"]
              and bc_temp1["bit_size"] == temp1["bit_size"])
        ballcosmos.shutdown()

    print(f"VERIFY_API OK ({checks} checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
