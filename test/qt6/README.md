# Qt 6 bindings tool regression tests

Headless bring-up tests for the COSMOS tools running on the new
libclang-generated Qt 6 bindings (qtbindings `qt6-libclang` branch).
Each test constructs a tool offscreen, verifies its UI, saves a
screenshot to /tmp, and exits non-zero on failure.

Run one:

```sh
env QT_QPA_PLATFORM=offscreen \
    RUBYLIB=/path/to/qtbindings/lib \
    COSMOS_USERPATH=$(pwd)/demo \
    bundle exec ruby test/qt6/test_launcher.rb
```

Run all:

```sh
for t in test/qt6/test_*.rb; do
  echo "== $t"
  env QT_QPA_PLATFORM=offscreen RUBYLIB=/path/to/qtbindings/lib \
      COSMOS_USERPATH=$(pwd)/demo bundle exec ruby "$t" || exit 1
done
```
