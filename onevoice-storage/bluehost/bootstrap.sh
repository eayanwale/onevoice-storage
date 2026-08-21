#!/bin/bash
#
# bootstrap.sh — run both halves in order.
#
# On EC2 these two phases were separated by time and mechanism: provision.sh's
# ancestor ran at AMI bake time under Packer, configure.sh's ancestor ran at
# first boot as cloud-init user data. A Bluehost VPS has no bake step, so they
# run back to back here — but they stay separate files, because the split is
# still useful: provision.sh needs no secrets and is safe to re-run for OS
# maintenance, configure.sh holds everything that touches credentials and
# application state.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/provision.sh"
"$SCRIPT_DIR/configure.sh"
