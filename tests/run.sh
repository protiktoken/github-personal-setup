#!/usr/bin/env bash

set -euo pipefail

test_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$test_directory/test-unix.sh"
bash "$test_directory/test-windows-contract.sh"