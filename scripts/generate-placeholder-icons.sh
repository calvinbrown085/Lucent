#!/usr/bin/env bash
# Convenience wrapper for the Swift icon generator. Idempotent — re-run
# any time to refresh placeholders. Run from the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."
swift scripts/generate-placeholder-icons.swift
