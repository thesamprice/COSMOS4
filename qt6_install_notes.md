# COSMOS4 Installation Guide for Qt 6

This guide covers installing COSMOS4 with Ruby 3.2+ and Qt 6 support.

## Overview

COSMOS4 has been modernized to run on:
- **Ruby 3.2 or newer** (verified on 3.2.3)
- **Qt 6** (verified on 6.4.2; newer 6.x works, see the note on generated
  bindings below)
- New libclang-generated Qt bindings from the `qt6-libclang` branch of
  <https://github.com/thesamprice/qtbindings>

14 of the 15 COSMOS tools have been ported to Qt 6 and are covered by the
test suite (19 tests, 656 checks). **OpenGL Builder is not ported** -- see
[Known Issues](#known-issues).

**You do not need libclang or the binding generator.** The qtbindings repo
ships pre-generated glue and the build picks the right file automatically;
see [Regenerating the bindings](#appendix-regenerating-the-bindings) for the
rare cases that need it.

## Quick start

Ubuntu/Debian, from nothing to a running Launcher:

```bash
sudo apt install -y build-essential git qt6-base-dev ruby ruby-dev bundler

export SRC=${SRC:-$HOME/src}
mkdir -p "$SRC" && cd "$SRC"

# 1. Qt 6 bindings (~1 minute to compile)
git clone -b qt6-libclang https://github.com/thesamprice/qtbindings.git
cd qtbindings/ext/qt6 && ruby extconf.rb && make

# 2. COSMOS itself
cd "$SRC"
git clone https://github.com/thesamprice/COSMOS4.git
cd COSMOS4
bundle config set --local path vendor/bundle   # avoids needing root for gems
bundle install
bundle exec rake build                          # COSMOS's own C extensions

# 3. Run it
export COSMOS_QT6_LIB=$SRC/qtbindings/lib
bundle exec ruby demo/Launcher
```

The first window is the legal agreement -- click *I Agree*.

The rest of this guide explains each step. To install COSMOS somewhere shared
rather than running it from the checkout, see
[Installing to a shared prefix](#installing-to-a-shared-prefix).

## Prerequisites

### System Dependencies

#### Ubuntu/Debian
```bash
sudo apt update
sudo apt install -y \
    build-essential \
    git \
    qt6-base-dev \
    ruby \
    ruby-dev \
    bundler
```

`qt6-base-dev` pulls in the Qt 6 Core/Gui/Widgets libraries and their
`pkg-config` files, which is all the bindings link against. You only need
libclang (`pip install libclang`, no apt package required) if you have to
*regenerate* the bindings for your Qt version -- see step 1.

#### macOS
```bash
brew install qt ruby
```

#### Fedora/RHEL
```bash
sudo dnf install -y \
    gcc-c++ \
    git \
    qt6-qtbase-devel \
    ruby \
    ruby-devel \
    rubygem-bundler
```

### Ruby

Ruby 3.2 or newer, with its development headers (the C extensions in
`ext/` and the Qt 6 bindings both need them):

```bash
ruby --version   # 3.2.3 or newer
```

If you need a different Ruby, use a version manager such as rbenv or RVM:

```bash
rbenv install 3.2.3 && rbenv local 3.2.3
# or
rvm install ruby-3.2.3 && rvm use 3.2.3
```

## Installation Steps

### 1. Build the Qt 6 Bindings

The Qt 6 bindings live in the `qt6-libclang` branch of the qtbindings fork.
They are a plain Ruby C extension built with `mkmf` -- not the cmake/smoke
`rake gem` flow the Qt 4 gem used.

```bash
# $SRC is wherever you keep checkouts; everything below is relative to it
export SRC=${SRC:-$HOME/src}
mkdir -p "$SRC" && cd "$SRC"

git clone -b qt6-libclang https://github.com/thesamprice/qtbindings.git
cd qtbindings

cd ext/qt6 && ruby extconf.rb && make
```

The build takes about a minute. `extconf.rb` finds Qt with `pkg-config`
(set `QT_PREFIX` to override) and prints which generated file it selected:

```
Using qt6_generated_6_4_2.cpp for Qt 6.4.2
```

No generator, no libclang, no cmake: the repo ships the generated glue in
`ext/qt6/generated/` and `extconf.rb` selects it for you.

If it reports a Qt version different from yours, that is expected and fine.
The shipped glue is generated against the *oldest* supported Qt, and Qt 6
keeps source compatibility across 6.x, so it builds on newer 6.x releases too
-- it simply does not bind API that Qt added after that version. You only need
to regenerate in the cases listed in
[Regenerating the bindings](#appendix-regenerating-the-bindings).

### 2. Clone and Install COSMOS4

```bash
cd "$SRC"
git clone https://github.com/thesamprice/COSMOS4.git
cd COSMOS4

# Install COSMOS dependencies (without Qt4)
bundle install

# Build COSMOS's own C extensions
bundle exec rake build
```

If `bundle install` fails with a permission error writing to the system gem
directory, install into the project instead:

```bash
bundle config set --local path vendor/bundle
bundle install
```

### 3. Set Environment Variables

Only one variable is strictly required: `COSMOS_QT6_LIB`, the qtbindings
`lib/` directory. `lib/cosmos/gui/qt.rb` puts it on the load path before
requiring `qt6`; plain `RUBYLIB` works too.

```bash
export COSMOS_QT6_LIB=$SRC/qtbindings/lib
```

To make it persistent, drop a helper script somewhere you can source:

```bash
cat > ~/cosmos_qt6_env.sh << 'EOF'
#!/bin/bash
# COSMOS Qt 6 environment
SRC=${SRC:-$HOME/src}

export COSMOS_QT6_LIB=$SRC/qtbindings/lib
export PATH=$SRC/COSMOS4/bin:$PATH

# The project COSMOS operates on. The checkout's own demo/ is a working
# project; point this at your own once you have one.
export COSMOS_USERPATH=${COSMOS_USERPATH:-$SRC/COSMOS4/demo}

echo "COSMOS Qt 6 environment configured (COSMOS_QT6_LIB=$COSMOS_QT6_LIB)"
EOF

chmod +x ~/cosmos_qt6_env.sh
```

Source it whenever you want to use COSMOS:

```bash
source ~/cosmos_qt6_env.sh
```

`COSMOS_USERPATH` is only a fallback for running a tool from outside any
project; it is set here so that case works too.

### 4. Run COSMOS

The `demo` project ships with the repo, so there is nothing to create:

```bash
cd "$SRC/COSMOS4"
bundle exec ruby demo/Launcher
```

No `COSMOS_USERPATH` is needed here. COSMOS finds the project by walking up
from the launched script's own directory, and `demo/` is a project -- see
[How COSMOS finds its own files](#how-cosmos-finds-its-own-files).

The first window is the **legal agreement dialog**; click *I Agree* and the
Launcher opens with all 15 tools. COSMOS shows this dialog on every start --
there is no flag to skip it.

Individual tools take the same form:

```bash
bundle exec ruby demo/tools/CmdTlmServer
bundle exec ruby demo/tools/PacketViewer
```

Drop `bundle exec` only if you installed the gems somewhere already on your
`GEM_PATH`; with `bundle config set --local path vendor/bundle` they live in
`./vendor/bundle` and `bundle exec` is required.

#### Running from inside `demo/`

`demo/Gemfile` is a separate bundle that fetches the released `cosmos` gem
rather than your checkout. To run from that directory against your local
COSMOS, point it at the checkout with `COSMOS_DEVEL`:

```bash
cd "$SRC/COSMOS4/demo"
COSMOS_DEVEL=$SRC/COSMOS4 bundle install
COSMOS_DEVEL=$SRC/COSMOS4 bundle exec ruby Launcher
```

Running from the repo root as shown above avoids the second bundle entirely,
so prefer it while developing.

#### You need a display

The tools are desktop GUIs. Over SSH, forward X11 (`ssh -X`) or use a local
session. `QT_QPA_PLATFORM=offscreen` makes them start without a display, but
nothing can click the legal dialog, so an offscreen Launcher hangs -- use the
test suite below for headless verification instead.

## Installing to a shared prefix

Everything above runs COSMOS straight from the checkout, which is what you
want while developing. To install it somewhere stable that does not depend on
your checkouts -- a shared location such as `/local/opt`, or `/opt/cosmos` --
use the `install_prefix` task.

Build first (the task refuses to run otherwise, rather than installing a
half-working tree):

```bash
cd "$SRC/COSMOS4"
bundle config set --local path vendor/bundle
bundle install
bundle exec rake build                     # COSMOS C extensions
# and the Qt 6 bindings, if you have not built them yet:
(cd "$SRC/qtbindings/ext/qt6" && ruby extconf.rb && make)

bundle exec rake install_prefix PREFIX=/local/opt QTBINDINGS=$SRC/qtbindings
```

`PREFIX` defaults to `/local/opt` and `QTBINDINGS` to `~/src/qtbindings`, so
with the layout used in this guide `bundle exec rake install_prefix` is
enough. `rake uninstall_prefix PREFIX=...` removes it again (it only deletes
the subdirectories it created, never the prefix itself).

### What gets installed

```
/local/opt/
  bin/       cosmos, rubysloc, cstol_converter, xtce_converter,
             dart_import, dart_util  -- wrappers that set RUBYLIB and
             GEM_PATH, plus cosmos_env.sh
  libexec/   the real scripts the wrappers exec
  lib/       cosmos.rb, cosmos/...   -- COSMOS library
             qt6.rb, qt6.so, Qt/...  -- Qt 6 bindings, flattened in
  gems/      vendored gem dependencies (a GEM_PATH root)
  data/  demo/  install/  config/
  cosmos.gemspec          -- lets a project bundle against this install
                             (COSMOS_DEVEL=<prefix>)
```

Directories and executables are `0755` and regular files `0644`, so others
can run the install while only the owner can update it.

### How COSMOS finds its own files

Two different paths matter, and mixing them up is the usual source of
confusion:

| Variable | Meaning | How it is set |
| --- | --- | --- |
| `Cosmos::PATH` | Where COSMOS itself is installed -- its `data/`, `demo/` and `install/` templates | **Derived, not configured.** `lib/cosmos/top_level.rb` computes it as two levels above itself, so with the library at `<prefix>/lib/cosmos/` it resolves to `<prefix>` |
| `Cosmos::USERPATH` | Your *project* -- its `config/`, `procedures/`, `outputs/`, `lib/` | Auto-detected; `COSMOS_USERPATH` is only a fallback (see below) |

So `Cosmos::PATH` follows the library automatically -- that is exactly why
`data/`, `demo/` and `install/` are installed directly under the prefix
rather than beside the executables. Verify it resolved correctly with:

```bash
RUBYLIB=/local/opt/lib ruby -e 'require "cosmos"; puts Cosmos::PATH'
# => /local/opt
```

**`COSMOS_USERPATH` does not override the project search.** COSMOS locates
your project by walking *up* from the running script's directory, and then up
from the current directory, looking for a directory that contains both
`config/system` and `config/targets`. Only if neither search finds one does it
fall back to `$COSMOS_USERPATH`:

```bash
cd ~/myproject && ruby -e 'require "cosmos"; puts Cosmos::USERPATH'
# => /home/you/myproject          (found by the search; no variable needed)

cd /tmp && COSMOS_USERPATH=~/myproject ruby -e 'require "cosmos"; puts Cosmos::USERPATH'
# => /home/you/myproject          (fallback used, since /tmp is not a project)
```

In practice this means: run a tool from inside its project and it just works;
set `COSMOS_USERPATH` when you must run from somewhere else. Setting it while
already inside a *different* project has no effect -- the search wins.

With no project found and no variable set, `Cosmos::USERPATH` degrades to `/`
and tools fail to find their configuration; that is the symptom of running
from the wrong directory.

### Using the install

```bash
source /local/opt/bin/cosmos_env.sh     # RUBYLIB, GEM_PATH, PATH

cosmos demo ~/myproject                 # create a project from the template
cd ~/myproject
ruby Launcher                           # project is auto-detected from the cwd
```

To launch from outside the project, name it explicitly:

```bash
COSMOS_USERPATH=~/myproject ruby ~/myproject/Launcher
```

The `cosmos*` wrappers in `bin/` set the environment themselves, so
`/local/opt/bin/cosmos demo ~/myproject` works without sourcing anything.
Sourcing `cosmos_env.sh` is what you need for a *project's own* scripts
(`Launcher`, `tools/CmdTlmServer`, ...), which are plain `ruby` invocations.

`COSMOS_QT6_LIB` is not needed with a prefix install -- the bindings are
installed into `<prefix>/lib`, which is already on `RUBYLIB`.

### Pointing your own project at the install

A COSMOS project's `Gemfile` (the one `cosmos demo`/`cosmos install` gives
you) reads:

```ruby
if ENV['COSMOS_DEVEL']
  gem 'cosmos', :path => ENV['COSMOS_DEVEL']
else
  gem 'cosmos'
end
```

and `tools/tool_launch.rb` runs `require 'bundler/setup'` before anything
else, so bundler decides which COSMOS you get. Point it at the install:

```bash
cd ~/myproject
COSMOS_DEVEL=/local/opt bundle install
COSMOS_DEVEL=/local/opt ruby Launcher
```

Export `COSMOS_DEVEL=/local/opt` in your shell profile and both commands
shorten back to `bundle install` / `ruby Launcher`. `COSMOS_QT6_LIB` is not
needed: the bindings are installed into the same `lib/` directory as COSMOS,
so bundler puts them on the load path along with it.

> **Do not leave `COSMOS_DEVEL` unset.** `gem 'cosmos'` carries no version
> constraint, so bundler resolves it against rubygems and installs
> **cosmos 5.x** -- the containerized web rewrite, a different product with no
> Qt GUI and no `Cosmos::Launcher`. The tool then fails *after* Qt has already
> started, which makes unrelated `libEGL`/GLX warnings look like the cause.
> Check which one you have with:
>
> ```bash
> ruby -e 'require "cosmos"; puts Cosmos::VERSION'   # 5.x means the wrong gem
> ```
>
> Pinning `gem 'cosmos', '~> 4.5'` is *not* a fix either -- that fetches the
> released Qt 4 COSMOS from rubygems, which does not work with these Qt 6
> bindings. The install is the only source of the ported code, so bundler has
> to be pointed at it explicitly.

`rake install_prefix` generates `<prefix>/cosmos.gemspec` for exactly this
purpose. It is generated rather than copied from the repo, whose gemspec
reads `Manifest.txt`, declares C extensions to compile, and reports version
`0.0.0` outside a release build -- none of which applies to an installed tree
whose extensions are already built.

## Verification

### Run Qt 6 Regression Tests

This is the way to verify the build without a display. The suite is headless
by design: it runs offscreen and auto-dismisses modal dialogs, so it does not
hang on the legal agreement.

```bash
cd "$SRC/COSMOS4"
export COSMOS_QT6_LIB=$SRC/qtbindings/lib

# One test
env QT_QPA_PLATFORM=offscreen COSMOS_USERPATH=$PWD/demo \
    bundle exec ruby test/qt6/test_launcher.rb

# All of them
for t in test/qt6/test_*.rb; do
  echo "== $t"
  env QT_QPA_PLATFORM=offscreen COSMOS_USERPATH=$PWD/demo \
      bundle exec ruby "$t" || exit 1
done
```

All 19 should pass (656 checks total) and leave screenshots in `/tmp`. Each
test prints `ok:` lines and ends with `TEST_<NAME> OK`. See
`test/qt6/README.md` for what the suite covers.

### Verify All Tools

Launch the COSMOS Launcher and verify that all tools start correctly:

1. **Command and Telemetry Server**
2. **Replay**
3. **Limits Monitor**
4. **Command Sender**
5. **Script Runner**
6. **Test Runner**
7. **Packet Viewer**
8. **Telemetry Viewer**
9. **Telemetry Grapher**
10. **Data Viewer**
11. **Telemetry Extractor**
12. **Command Extractor**
13. **Handbook Creator**
14. **Table Manager**

**OpenGL Builder** is the exception: it is not ported to Qt 6 and exits with
`uninitialized constant Qt::GLWidget`.

## Optional: Qt 4 Legacy Support

If you need to use the legacy Qt 4 bindings (requires Qt 4.8 and Ruby <= 2.x):

```bash
export COSMOS_QT4=1
bundle install
```

This will install the old qtbindings gem that works with Qt 4.8. See `ubuntu22_install_notes.md` for detailed Qt 4 installation instructions.

## Troubleshooting

### Qt libraries not found

If you get errors about missing Qt libraries, ensure Qt 6 is in your library path:

```bash
# Linux
export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH

# macOS
export DYLD_LIBRARY_PATH=/opt/homebrew/opt/qt6/lib:$DYLD_LIBRARY_PATH
```

### The bindings fail to compile

Errors like `'class QImage' has no member named 'flipped'` or
`'returnPressed' is not a member of 'QAbstractSpinBox'` mean the generated
glue was produced against a **newer Qt** than you are building against --
those methods do not exist in your Qt yet. `extconf.rb` prints which file it
chose; regenerate for your version, see
[Regenerating the bindings](#appendix-regenerating-the-bindings).

### The extension builds but fails to load

An `undefined symbol` from `require "qt6"` means the glue referenced a Qt
symbol your Qt libraries do not export -- again a version mismatch. List what
is unresolved (anything without an `@Qt_6` version tag is a real problem),
then regenerate:

```bash
nm -DCu ext/qt6/qt6.so | grep -v @ | grep ^Q
```

### `cannot load such file -- cosmos/ext/platform`

COSMOS's own C extensions have not been compiled yet:

```bash
cd "$SRC/COSMOS4" && bundle exec rake build
```

### `Bundler::PermissionError` writing to the gem directory

Install the gems into the project rather than system-wide:

```bash
bundle config set --local path vendor/bundle
bundle install
```

### `cannot load such file -- cosmos`, run from outside the project

`tools/tool_launch.rb` calls `require 'bundler/setup'`, and bundler finds the
Gemfile by searching upward from the **current directory**, not from the
script's location. With no Gemfile above the cwd it does not raise -- it
checks `Bundler.in_bundle?` and silently does nothing -- so no bundle is set
up, nothing puts COSMOS on the load path, and the next line fails:

```
LoadError: cannot load such file -- cosmos
    tools/tool_launch.rb:15
```

The tell is a relative script path in the backtrace (`gsw/proj/Launcher:13`),
meaning you launched it from a parent directory. Run from inside the project:

```bash
cd ~/myproject && ruby Launcher
```

or name the Gemfile explicitly:

```bash
BUNDLE_GEMFILE=~/myproject/Gemfile ruby ~/myproject/Launcher
```

Note that `Cosmos::USERPATH` still resolves correctly from a parent
directory, so COSMOS gives no hint that you are outside the bundle.

### `cannot load such file -- 3.2/qtruby4` from a custom widget

A custom widget or library doing the Qt 4 idiom

```ruby
require 'Qt'     # or 'Qt4'
```

reaches qtbindings' Qt 4 entry point, which requires
`"<ruby version>/qtruby4"` -- an extension that exists only in a Qt 4 build.
Use what the stock COSMOS widgets use instead:

```ruby
require 'cosmos/gui/qt'
```

That resolves to the Qt 6 bindings. Grep your project for `require 'Qt'` and
`require 'Qt4'`; none of the 49 widgets shipped with COSMOS require them
directly, so any hit is project code that needs updating. Note that the
require is only the first hurdle -- a widget written against Qt 4 may also use
API that changed in Qt 6.

### Ruby version issues

COSMOS4 with Qt 6 requires Ruby 3.2 or newer. If you have multiple Ruby
versions installed:

```bash
ruby --version  # Verify you're using Ruby 3.2+
which ruby      # Check which Ruby is in your PATH
```

### libEGL / GLX warnings over SSH X11 forwarding

Running a tool through `ssh -X` prints warnings like:

```
libEGL warning: DRI3 error: Could not get DRI3 device
libEGL warning: Ensure your X server supports DRI3 to get accelerated rendering
No matching fbConfigs or visuals found
glx: failed to create drisw screen
```

These are harmless. A forwarded X connection has no direct rendering, so
Mesa cannot get a DRI3 device and its software GLX fallback finds no usable
visual. Qt renders widgets with the raster engine, not OpenGL, so every
ported tool works normally -- only the unported OpenGL Builder needs GL.

To silence them, force software GL:

```bash
export LIBGL_ALWAYS_SOFTWARE=1
```

### Headless / offscreen

`QT_QPA_PLATFORM=offscreen` lets the tools start without a display:

```bash
export QT_QPA_PLATFORM=offscreen
```

Note that the **Launcher will hang** this way: it opens the legal agreement
dialog on startup and nothing headless can click *I Agree*. For unattended
verification use the Qt 6 test suite instead, which dismisses modals
automatically. For interactive headless use, forward X11 with `ssh -X`.

You may also see `This plugin does not support propagateSizeHints()` and
`... does not support raise()` on the offscreen platform. Both are harmless
notices from Qt, not errors.

## Performance Notes

- Qt 6 bindings use libclang-generated code, which is more maintainable than the legacy Qt 4 bindings
- All C extensions have been ported to work with modern Ruby (3.2+)
- The system has been tested with the full spec suite (2453 examples)

## Appendix: Regenerating the bindings

**Most people never need this.** The pre-generated glue in
`ext/qt6/generated/` covers normal installs. Regenerate only if:

- your Qt is *older* than every shipped file (`extconf.rb` aborts and lists
  what it has), or
- the bindings fail to compile or fail to load with an `undefined symbol`, or
- you want API that Qt added after the shipped version, or you added classes
  to the `CLASSES` list in `generator/regen.sh`.

It takes a few seconds and needs libclang's Python bindings -- the pip wheel,
not a system package:

```bash
cd "$SRC/qtbindings"
python3 -m venv generator-venv && generator-venv/bin/pip install libclang
# no venv module? pip install --target generator-libs libclang

./generator/regen.sh
cd ext/qt6 && ruby extconf.rb && make
```

`regen.sh` takes no arguments: it finds Qt with `pkg-config` (override with
`QT_PREFIX`), borrows libclang's builtin headers from an installed clang
(override with `CPLUS_INCLUDE_PATH`), and writes
`ext/qt6/generated/qt6_generated_<your qt version>.cpp`. Commit that file to
ship bindings for that Qt version.

Why per-version files: the generator binds exactly the API the local Qt
headers declare, so glue generated against a newer Qt calls methods an older
Qt has not added yet (`QAbstractSpinBox::returnPressed`, `QImage::flipped`,
`QPalette::accent`, ...) and will not compile. `extconf.rb` picks the newest
file your Qt is new enough for; falling back to an older file is safe because
it only uses API a newer Qt still provides, while the reverse is not.

## Additional Resources

- [COSMOS Documentation](https://ballaerospace.github.io/cosmos-website/)
- [qtbindings qt6-libclang branch](https://github.com/thesamprice/qtbindings/tree/qt6-libclang)
- Qt 6 test suite: `test/qt6/README.md`
- Original Qt 4 installation notes: `ubuntu22_install_notes.md`

## Known Issues

- **OpenGL Builder does not run on Qt 6.** `lib/cosmos/gui/opengl/gl_viewer.rb`
  subclasses `Qt::GLWidget` (Qt 4's `QGLWidget`), which the Qt 6 bindings do
  not provide -- no QOpenGL class is in the generator's class list. Launching
  it fails with `NameError: uninitialized constant Qt::GLWidget`. Porting it
  means binding `QOpenGLWidget` and rewriting the viewer against the Qt 6
  OpenGL API, since `QGLWidget` was removed in Qt 6.
- DART is now opt-in (`COSMOS_DART=1`) due to Rails 5.1 incompatibility with modern Ruby
- Some distributions may package Qt 6 with different library names
- The Launcher shows the legal agreement dialog on every start, so it cannot
  be run unattended offscreen

## Support

For issues specific to:
- COSMOS4: Check the GitHub issues
- Qt 6 bindings: Report to the qtbindings repository
- Qt 6 itself: Consult Qt documentation
