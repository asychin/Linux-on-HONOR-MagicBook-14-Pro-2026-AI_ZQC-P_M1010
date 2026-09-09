#!/usr/bin/env bash
# Build the read-only EC module and the acpi_call module for the running kernel.
# Load them with:  sudo insmod honor-ec-rail.ko && sudo insmod acpi_call/acpi_call.ko
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "== building honor-ec-rail =="
make

echo "== building acpi_call =="
if [[ ! -d acpi_call/.git ]]; then
    git clone --depth 1 https://github.com/nix-community/acpi_call.git acpi_call
fi
make -C acpi_call LLVM=1 KDIR="/lib/modules/$(uname -r)/build"

echo
echo "Built:"
echo "  tools/honor-boost/honor-ec-rail.ko"
echo "  tools/honor-boost/acpi_call/acpi_call.ko"
echo
echo "Load with:"
echo "  sudo insmod honor-ec-rail.ko"
echo "  sudo insmod acpi_call/acpi_call.ko"
