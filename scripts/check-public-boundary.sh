#!/usr/bin/env bash
set -euo pipefail

forbidden_pattern='(^|/)(shared/rust-core|models|ios/Distribution/Native|android/rust-core)(/|$)|\.xcframework/|\.(aar|so|a|dylib|onnx|wav|m4a|mp3)$'
violations="$(git ls-files | grep -E "${forbidden_pattern}" || true)"

if [[ -n "${violations}" ]]; then
  echo "Proprietary runtime, model, audio, or binary artifacts must not be tracked:" >&2
  echo "${violations}" >&2
  exit 1
fi

for required in LICENSE NOTICE SECURITY.md; do
  if [[ ! -s "${required}" ]]; then
    echo "Required public-distribution file is missing: ${required}" >&2
    exit 1
  fi
done

echo "Public-source boundary verified."
