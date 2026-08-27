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
    local src="$1" dst="$2" rel_dst rel_src rel
    if [[ -f "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp -f "$src" "$dst"
        rel_dst="${dst#$ROOT/}" rel_src="${src#$SIBLINGS/}"
        echo "[sync] $rel_dst ← $rel_src"
        copied=$((copied + 1))
    else
        rel="${src#$SIBLINGS/}"
        echo "[skip] $rel not delivered yet"
        skipped=$((skipped + 1))
    fi
}

# resolve_src — find a delivered archive across the delivery layouts that have
# been canon at different times. The path canon is `prebuilt/<target>/<lib>`
# (no `/lib/` segment); repos that predate it deliver to `prebuilt/lib/<target>/`.
# Callers may append extra per-repo fallbacks as trailing arguments.
#
# Returns the first path that EXISTS, or the canonical path when none do, so
# the caller's own missing-file branch reports against the path we actually want.
resolve_src() { # $1=repo_root $2=target $3=libname [extra fallback paths...]
    local repo="$1" t="$2" lib="$3"; shift 3
    local canon="$repo/prebuilt/$t/$lib"
    local cand
    for cand in "$canon" "$repo/prebuilt/lib/$t/$lib" "$@"; do
        if [[ -f "$cand" ]]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    printf '%s\n' "$canon"
}

for dep in "${ALL_DEPS[@]}"; do
    lib="lib$(echo "$dep" | tr '[:upper:]' '[:lower:]').a"
    for t in "${TARGETS[@]}"; do
        copy_one "$(resolve_src "$SIBLINGS/$dep" "$t" "$lib")" "$ROOT/prebuilt/$t/lib/$lib"
    done
done

# forMetal: macOS only. Archive + runtime .metallib (installed beside the binary).
copy_one "$(resolve_src "$SIBLINGS/forMetal" macos libformetal.a)" "$ROOT/prebuilt/macos/lib/libformetal.a"
# v1.2 rename (2026-06-04): fm_kernels.metallib → fmet_kernels.metallib; the
# loader in libformetal.a now searches for the fmet_ name.
copy_one "$(resolve_src "$SIBLINGS/forMetal" macos fmet_kernels.metallib)" "$ROOT/prebuilt/macos/lib/fmet_kernels.metallib"

# forCUDA: GPU kernels for everything that isn't macOS. thor falls back to
# forCUDA's legacy linux-arm64 delivery layout until it adopts short names.
for t in thor linX86 winX86; do
    # thor additionally keeps a legacy linux-arm64 delivery layout.
    extra=()
    [[ "$t" == "thor" ]] && extra=("$SIBLINGS/forCUDA/prebuilt/linux-arm64/lib/libforcuda.a")
    copy_one "$(resolve_src "$SIBLINGS/forCUDA" "$t" libforcuda.a "${extra[@]+"${extra[@]}"}")" \
             "$ROOT/prebuilt/$t/lib/libforcuda.a"
done

echo "----"
echo "[sync] done: $copied copied, $skipped skipped (skips are fine — deliveries land per-target over time)"
