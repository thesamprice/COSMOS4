# Platform-Specific Notes

## Windows
- Uses MinGW64/32 toolchain (MSYS2)
- Native extensions built with `rake devkit` task
- Building gems not supported on Windows (file permissions)

## Linux
- Requires qt4 development packages
- May need older gcc (7.5.0) for qt4 compatibility; see `ubuntu22_install_notes.md`
- Use `ruby-termios` gem for serial support

## macOS
- Qt frameworks required
- Use `.bundle` extension for shared libraries (not `.so`)

## Docker
Maintained in a separate repository: https://github.com/BallAerospace/cosmos-docker
