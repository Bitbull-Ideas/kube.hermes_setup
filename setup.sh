#!/usr/bin/env bash
# Purpose: Provide the stable compatibility entry point for configuration setup.
# Scope: Resolve this repository's path and forward every argument to configure.sh unchanged.
# Requirements: Bash and the repository's configure.sh.
# Usage: ./setup.sh [configure.sh options]
# Exit status: Mirrors configure.sh and therefore indicates setup success or failure.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$ROOT_DIR/configure.sh" "$@"
