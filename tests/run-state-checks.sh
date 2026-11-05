#!/bin/bash
# This target only exercises state and isolated preferences. It starts no app.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=$(mktemp -d)
trap 'rm -r "$scratch"' EXIT
swiftc CouchPilot/{TriggerManager,RadialSelection,RadialOverlay,MouseEmulation,AppSwitcher,SettingsStore,ControllerModel,ContentView,VaderExclusiveInput}.swift \
    tests/StateChecks.swift -o "$scratch/state-checks"
"$scratch/state-checks"
