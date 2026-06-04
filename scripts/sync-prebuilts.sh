#!/usr/bin/env bash
# sync-prebuilts.sh — copy prebuilt kernels from sibling dep repos into ./prebuilt/
#
# Run after a sibling repo re-delivers. The copies are COMMITTED (binary
# redistribution is permitted; dep source stays closed). The build never
# reads sibling paths — only what this script has placed locally.
#
# Targets (org short names, no hyphenated triples): macos | thor | linX86 | winX86
# Matrix:
#   forAgent forLearn forMCP forAI forNLP  → every target
#   forMetal                               → macos ONLY (decision 2026-06-04)
#   forCUDA                                → thor linX86 winX86
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIBLINGS="$(cd "$ROOT/.." && pwd)"
TARGETS=(macos thor linX86 winX86)
ALL_DEPS=(forAgent forLearn forMCP forAI forNLP)

copied=0
skipped=0

copy_one() { # $1=src $2=dst
    local src="$1" dst="$2"
    if [[ -f "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp -f "$src" "$dst"
        echo "[sync] ${dst#"$ROOT"/} ← ${src#"$SIBLINGS"/}"
        copied=$((copied + 1))
    else
        echo "[skip] ${src#"$SIBLINGS"/} not delivered yet"
        skipped=$((skipped + 1))
    fi
}

for dep in "${ALL_DEPS[@]}"; do
    lib="lib$(echo "$dep" | tr '[:upper:]' '[:lower:]').a"
    for t in "${TARGETS[@]}"; do
        copy_one "$SIBLINGS/$dep/prebuilt/lib/$t/$lib" "$ROOT/prebuilt/$t/lib/$lib"
    done
done

# forMetal: macOS only. Archive + runtime .metallib (installed beside the binary).
copy_one "$SIBLINGS/forMetal/prebuilt/lib/macos/libformetal.a" "$ROOT/prebuilt/macos/lib/libformetal.a"
copy_one "$SIBLINGS/forMetal/prebuilt/lib/macos/fm_kernels.metallib" "$ROOT/prebuilt/macos/lib/fm_kernels.metallib"

# forCUDA: GPU kernels for everything that isn't macOS. thor falls back to
# forCUDA's legacy linux-arm64 delivery layout until it adopts short names.
for t in thor linX86 winX86; do
    src="$SIBLINGS/forCUDA/prebuilt/lib/$t/libforcuda.a"
    if [[ "$t" == "thor" && ! -f "$src" ]]; then
        src="$SIBLINGS/forCUDA/prebuilt/linux-arm64/lib/libforcuda.a"
    fi
    copy_one "$src" "$ROOT/prebuilt/$t/lib/libforcuda.a"
done

echo "----"
echo "[sync] done: $copied copied, $skipped skipped (skips are fine — deliveries land per-target over time)"
