#!/bin/zsh
# Regenerates LANNudge/Licenses.txt (bundled in the app and copied into the DMG): this project's MIT
# license plus, for each SwiftPM dependency, its version, NOTICE and the Apache License 2.0 text,
# as Apache-2.0 requires when redistributing binaries. Run after dependency updates.
set -euo pipefail
cd "$(dirname "$0")/.."

checkouts=${1:-build/DerivedData.noindex/SourcePackages/checkouts}
resolved=LANNudge.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
out=LANNudge/Licenses.txt
packages=(swift-certificates swift-crypto swift-asn1)

for p in $packages; do
  [[ -f $checkouts/$p/LICENSE.txt ]] || { echo "✘ $checkouts/$p missing; build once first"; exit 1; }
done

{
  print -- "LAN Nudge — Licenses"
  print -- "====================\n"
  cat LICENSE
  print -- "\n\nThird-party software"
  print -- "====================\n"
  print -- "LAN Nudge includes the following packages, each licensed under the Apache License 2.0"
  print -- "(full text at the end). swift-crypto bundles BoringSSL (Apache License 2.0) and"
  print -- "fiat-crypto generated code (MIT / Apache-2.0 / BSD-1-Clause, used under Apache-2.0).\n"
  for p in $packages; do
    version=$(python3 -c "import json,sys; print(next(x['state']['version'] for x in json.load(open(sys.argv[1]))['pins'] if x['identity']==sys.argv[2]))" $resolved $p)
    print -- "- $p $version — https://github.com/apple/$p"
  done
  for p in $packages; do
    print -- "\n\nNOTICE — $p"
    print -- "------------------------------\n"
    cat $checkouts/$p/NOTICE.txt
  done
  print -- "\n\nApache License 2.0"
  print -- "------------------\n"
  cat $checkouts/swift-certificates/LICENSE.txt
} > $out
echo "✔ $out ($(wc -l < $out | tr -d ' ') lines)"
