# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Ball Aerospace COSMOS is a Ruby-based command and control system for embedded systems testing. It provides a complete suite of tools for sending commands, receiving telemetry, logging, playback, and test automation. The system uses Qt bindings for GUI tools and provides both real-time and offline analysis capabilities. This is the `cosmos4` branch, which is being modernized (Ruby/puma/json updates, extracting the database).

## Building and Testing

Prerequisites: Ruby 2.4+ (MRI or JRuby); on non-Windows also cmake, qt 4.8.x, gcc (7.5.0 recommended on Ubuntu 22, see `ubuntu22_install_notes.md`).

```bash
bundle install                 # install dependencies
bundle exec rake build         # build C extensions (MRI only) - REQUIRED before specs
COSMOS_NO_SIMPLECOV=1 bundle exec rspec spec/path/to/file_spec.rb   # one spec file
```

**Testing rules (details and known failures in [docs/testing.md](docs/testing.md)):**
- Always set `COSMOS_NO_SIMPLECOV=1`, otherwise specs upload coverage to codecov.io.
- Never use `COSMOS_NO_EXT=1`; the pure-Ruby fallback is broken and fails hundreds of specs.
- The full headless suite takes ~13 min. Run it in the background with output to a log file.
- `spec/gui/**` needs Qt and can't load headless; exclude it.

## Architecture

### Core Components (`lib/cosmos/`)
- `packets/` - Packet definition, telemetry, command structures, and binary accessors
- `interfaces/` - Communication layer (TCP/IP, UDP, Serial). Key classes: `TcpipClientInterface`, `TcpipServerInterface`, `UdpInterface`, `SerialInterface`
- `tools/cmd_tlm_server/` - Command and Telemetry Server (CmdTlmServer), the heart of real-time functionality; JSON-RPC API in `api.rb`
- `config/` - Configuration file parsers for targets, commands, telemetry
- `script/` - Scripting API for test automation
- `streams/` - Low-level data stream handling
- `processors/`, `conversions/` - Telemetry processors and data conversions
- `packet_logs/` - Binary log file reading/writing
- `io/` - JSON-DRb server/client (puma-based)
- `gui/` - Qt-based GUI widgets and components
- `ext/` - Compiled output of the C extensions in `ext/cosmos/ext/` (CRC, packet parsing, etc.)

### Tools (`lib/cosmos/tools/`)
cmd_tlm_server (central hub), replay, limits_monitor, cmd_sender, script_runner, test_runner, packet_viewer, tlm_viewer, tlm_grapher, data_viewer, tlm_extractor, cmd_extractor, handbook_creator, table_manager, opengl_builder.

### Data Flow
Commands: Tool/Script -> CmdTlmServer API -> Interface -> Target hardware.
Telemetry: Target hardware -> Interface (identifies packet) -> CmdTlmServer -> tools/loggers.

### Packet Processing
- All packets inherit from `Cosmos::Packet`
- Items accessed via `packet.read("ITEM_NAME")` / `packet.write("ITEM_NAME", value)`
- Binary access through `BinaryAccessor` (C extension in MRI, constants like `MAX_UINT16` come from it)
- Conversions applied on read (raw -> converted) and write (converted -> raw)

### Scripting API (`lib/cosmos/script/`, `lib/cosmos/top_level.rb`)
`cmd("TARGET COMMAND with PARAM1 value")`, `tlm("TARGET PACKET ITEM")`, `check(...)`, `wait_check(...)`.

## Development Notes

- After modifying C code in `ext/cosmos/ext/<name>/` (`extconf.rb`, `*.c`, `*.h`), rerun `bundle exec rake build`.
- Gemspec pins `puma ~> 3.10`; don't use puma 5+ only APIs.
- Many Ruby files start with `# encoding: ascii-8bit`; keep it in files that have it.
- Tests in `spec/` mirror `lib/` paths.

## More Documentation

- [docs/testing.md](docs/testing.md) - test setup, running, gotchas, known failures
- [docs/configuration.md](docs/configuration.md) - system/target config files and keyword formats
- [docs/release-and-quality.md](docs/release-and-quality.md) - release process, metrics, stress tests
- [docs/platforms.md](docs/platforms.md) - Windows/Linux/macOS notes, Docker
