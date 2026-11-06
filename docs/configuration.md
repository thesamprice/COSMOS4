# Configuration System

COSMOS uses text-based configuration files in the `config/` directory.

## System Configuration (`config/system/system.txt`)
- `DECLARE_TARGET` - Register targets in the system
- `PORT` - Define network ports for services
- `PATH` - Configure output directories
- `DEFAULT_PACKET_LOG_WRITER/READER` - Set logging backend

## Target Configuration (`config/targets/TARGETNAME/`)
- `cmd_tlm/` - Command and telemetry definitions
  - `*_cmds.txt` - Command packet definitions with `COMMAND` keyword
  - `*_tlm.txt` - Telemetry packet definitions with `TELEMETRY` keyword
- `lib/` - Target-specific Ruby libraries
- `procedures/` - Test scripts for this target
- `screens/` - Telemetry viewer screen definitions

## File Format
- Uses ERB templating (e.g., `<%= @target_name %>`)
- Supports partials with `<%= render "_partial.txt", locals: {...} %>`
- Command parameters: `PARAMETER name bit_offset bit_size type min max default description`
- Telemetry items: `APPEND_ITEM name bit_size type description`
- States: `STATE name value [HAZARDOUS]`
- Limits: `LIMITS set persistence enabled red_low yellow_low yellow_high red_high [green_low green_high]`
- Conversions: `POLY_READ_CONVERSION` for telemetry conversion
