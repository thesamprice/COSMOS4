# Release Process and Code Quality

## Release
Releases require the VERSION environment variable:
```bash
rake release VERSION=X.X.X        # update version and build
rake commit_release VERSION=X.X.X # commit and tag
rake gem VERSION=X.X.X            # build gem
```
The build process:
1. Updates `lib/cosmos/version.rb`
2. Generates CRC checksums in `data/crc.txt`
3. Builds native extensions
4. Runs tests
5. Updates manifest
6. Creates gem file

## Code Quality
```bash
rake metrics
flog lib > flog_report.txt
flay lib > flay_report.txt
reek lib > reek_report.txt
roodi -config=roodi.yml lib > roodi_report.txt
```

## Stress testing
`rake stress` runs the specs with `GC.stress = true`.
