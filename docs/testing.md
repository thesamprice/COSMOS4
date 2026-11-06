# Testing

## Setup (once per machine)
```bash
bundle install        # also checks out the qtbindings git source
bundle exec rake build   # compiles C extensions into lib/cosmos/ext
```
Without `rake build`, every spec fails at `require 'cosmos/ext/platform'`.

## Running specs
```bash
export COSMOS_NO_SIMPLECOV=1   # see "Gotchas"
bundle exec rspec spec/packets/commands_spec.rb          # single file
bundle exec rspec --exclude-pattern "spec/gui/**/*_spec.rb"   # everything headless
```
The full headless suite takes ~13 minutes and exceeds the 10 minute tool limit, so
run it in the background and redirect output to a log file.

Quick commanding smoke test: `spec/packets/commands_spec.rb`,
`spec/packets/binary_accessor_spec.rb`, `spec/script/commands_spec.rb`,
`spec/tools/cmd_tlm_server/commanding_spec.rb`, `spec/tools/cmd_tlm_server/api_spec.rb`.

## Gotchas
- **Codecov upload**: `spec/spec_helper.rb` uploads coverage to codecov.io unless
  `COSMOS_NO_SIMPLECOV` is set. Always set it for local runs.
- **Do not use `COSMOS_NO_EXT=1`**: `binary_accessor.rb` only defines `MAX_UINT16` etc.
  when `ENV['COSMOS_NO_ENV']` is set (likely a typo for `COSMOS_NO_EXT`), so the pure-Ruby
  path raises `NameError` and hundreds of specs fail.
- **Qt**: `spec/gui/**` requires the `Qt` gem and fails to load on headless machines.
- **Known environment failures** (not regressions): the 5 TlmViewer examples in
  `spec/script/tools_spec.rb` (need the GUI process on port 7778).
- **Order-dependent examples**: running only the commanding files together can fail
  `api_spec` `get_cmd_time`, `override_tlm`, `get_all_cmd_info`. They pass in the full run.
- **puma**: the gemspec pins `puma ~> 3.10` (installed 3.12.6). Code written for puma 5+
  APIs (e.g. `Server#stats` returning a Hash) breaks `get_server_status`.
