#!/usr/bin/env bash
set -euo pipefail

show_help() {
	cat <<'EOF'
Bitrot Guard performance suite (placeholder)
Usage: perf.sh [--help]
Runs forthcoming performance benchmarks comparing single vs multi-worker throughput.
EOF
}

case "${1:-}" in
	-h|--help)
		show_help
		exit 0
		;;
	*)
		show_help
		exit 0
		;;
esac
