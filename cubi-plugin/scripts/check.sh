#!/bin/zsh
# Builds and tests the Cubi plugin's helper. Run it after changing LANNudge/Protocol.swift,
# Identity.swift, PeerNetwork.swift or ReceiveGate.swift: the helper compiles those files too.
# The app itself (project.yml, LANNudge.xcodeproj) does not include anything under cubi-plugin/.
set -euo pipefail
cd "$(dirname "$0")/../helper"

for f in Sources/LanNudgeHelper/*.swift(@); do
  [[ -e $f ]] || { echo "✘ $f points at a file that is gone"; exit 1; }
done

flags=()
# Command Line Tools keep swift-testing outside the default search paths; Xcode does not need this.
if [[ $(xcode-select -p) == */CommandLineTools ]]; then
  fw=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  lib=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
  flags=(-Xswiftc -F$fw -Xlinker -F$fw -Xlinker -rpath -Xlinker $fw -Xlinker -rpath -Xlinker $lib)
fi

swift build
swift test $flags
echo "✔ helper builds and its tests pass"
