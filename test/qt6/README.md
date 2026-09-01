# Qt 6 bindings tool regression tests

Headless bring-up tests for the COSMOS tools running on the new
libclang-generated Qt 6 bindings (the `qt6-libclang` branch of
<https://github.com/thesamprice/qtbindings>).
Each test constructs a tool offscreen, verifies its UI, saves a
screenshot to /tmp, and exits non-zero on failure.

`test_bindings.rb` is the exception: it exercises bindings behaviour no
tool test reaches -- the Ruby-driven application event loop, QObject
wrapper identity and lifetime, and the Ruby-driven `Qt::Menu#exec`.

Run one:

```sh
env QT_QPA_PLATFORM=offscreen \
    COSMOS_QT6_LIB=/path/to/qtbindings/lib \
    COSMOS_USERPATH=$(pwd)/demo \
    bundle exec ruby test/qt6/test_launcher.rb
```

Run all:

```sh
for t in test/qt6/test_*.rb; do
  echo "== $t"
  env QT_QPA_PLATFORM=offscreen COSMOS_QT6_LIB=/path/to/qtbindings/lib \
      COSMOS_USERPATH=$(pwd)/demo bundle exec ruby "$t" || exit 1
done
```

## The telemetry log fixture

`tlm_extractor`, `tlm_grapher`, `replay` and `data_viewer` read a packet log
back. They use the newest `*_tlm.bin` under `Cosmos::System.paths['LOGS']`
when the machine has one, and otherwise fall back to the committed
`fixtures/qt6_demo_tlm.bin` (see `helper.rb#tlm_log_file`). Set
`COSMOS_QT6_FORCE_FIXTURE=1` to take the fixture path even when a local log
exists. `fixtures/build_tlm_log.rb` regenerates the fixture from the demo's
own simulated target.
