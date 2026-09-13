#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p build
cc -Wall -Wextra -O2 Tools/agent-guard-open-probe.c -o build/agent-guard-open-probe
printf 'Built build/agent-guard-open-probe\n'
