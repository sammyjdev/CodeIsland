#!/bin/bash
# Gate for the LLMOps package. Run from anywhere; extra args go to `swift test`
# (e.g. ./test.sh --filter ProfileTests).
#
# Why the flags: this machine has CommandLineTools only. The default swift-build
# backend dies with "Unknown error parsing property list", and the native build
# system does not add the CLT frameworks dir where Testing.framework lives.
set -euo pipefail
cd "$(dirname "$0")"
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test --build-system native \
    -Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" "$@" 2>&1 | grep -v 'has been deprecated'
