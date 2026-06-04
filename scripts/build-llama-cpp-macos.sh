#!/usr/bin/env bash
# build-llama-cpp-macos.sh — build libllama.a with embedded Metal shaders
#
# Produces: prebuilt/macos/lib/libllama.a
#
# Pinned commit: bumped manually after testing. Edit LLAMA_CPP_REF below.
#
# Requirements: cmake, Xcode CLT (for `metal` compiler + Metal SDK), git.

set -euo pipefail

# Pinned llama.cpp commit. Update deliberately after smoke-testing.
# Choose a tagged release for stability — see https://github.com/ggml-org/llama.cpp/releases
LLAMA_CPP_REPO="https://github.com/ggml-org/llama.cpp.git"
LLAMA_CPP_REF="${LLAMA_CPP_REF:-master}"   # TODO: pin to a tag like b4500 once smoke-tested

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor/llama.cpp"
OUT_LIB_DIR="${REPO_ROOT}/prebuilt/macos/lib"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "[error] This script targets darwin-arm64 only. Detected: $(uname -s)/$(uname -m)" >&2
    exit 1
fi

mkdir -p "${OUT_LIB_DIR}"

# Clone or update the vendor checkout
if [[ ! -d "${VENDOR_DIR}/.git" ]]; then
    echo "[build-llama] cloning ${LLAMA_CPP_REPO} into vendor/llama.cpp..."
    git clone --depth 1 --branch "${LLAMA_CPP_REF}" "${LLAMA_CPP_REPO}" "${VENDOR_DIR}" 2>/dev/null \
        || git clone "${LLAMA_CPP_REPO}" "${VENDOR_DIR}"
fi

cd "${VENDOR_DIR}"

# If LLAMA_CPP_REF is a SHA or tag, check it out
if [[ "${LLAMA_CPP_REF}" != "master" ]]; then
    git fetch --depth 1 origin "${LLAMA_CPP_REF}" || true
    git checkout "${LLAMA_CPP_REF}"
fi

CURRENT_REF="$(git rev-parse --short HEAD)"
echo "[build-llama] building at ${CURRENT_REF}"

# CMake build with Metal shaders embedded into libggml-metal.
#
# Key flags:
#   GGML_METAL=ON                  → enable Metal backend
#   GGML_METAL_EMBED_LIBRARY=ON    → bake .metallib into the static archive (no runtime file needed)
#   BUILD_SHARED_LIBS=OFF          → static linking
#   LLAMA_CURL=OFF                 → we don't need llama.cpp's curl (Wintermolt has its own)
#   LLAMA_BUILD_EXAMPLES=OFF       → skip the CLI tools
#   LLAMA_BUILD_SERVER=OFF         → skip the HTTP server
#   LLAMA_BUILD_TESTS=OFF          → skip tests
mkdir -p build-static
cd build-static
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_ACCELERATE=ON \
    -DGGML_BLAS=OFF \
    -DLLAMA_CURL=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_TESTS=OFF
cmake --build . --config Release -j

# Merge libllama.a + libggml*.a into a single fat archive so Wintermolt's
# build.zig only has to addObjectFile one path.
echo "[build-llama] merging static archives..."
cd "${REPO_ROOT}"
TMP_MERGE="$(mktemp -d)"
cd "${TMP_MERGE}"

# Find every static archive produced by the build (libllama.a, libggml.a, libggml-base.a, libggml-metal.a, libggml-cpu.a, libggml-blas.a)
ARCHIVES=()
while IFS= read -r -d '' a; do
    ARCHIVES+=("${a}")
done < <(find "${VENDOR_DIR}/build-static" -name "lib*.a" -print0)

if [[ ${#ARCHIVES[@]} -eq 0 ]]; then
    echo "[build-llama] error: no .a archives produced" >&2
    exit 1
fi

# libtool -static merges archives without needing to extract per-symbol.
libtool -static -o "${OUT_LIB_DIR}/libllama.a" "${ARCHIVES[@]}"

cd "${REPO_ROOT}"
rm -rf "${TMP_MERGE}"

echo ""
echo "[build-llama] done."
echo "  artifact:  ${OUT_LIB_DIR}/libllama.a"
echo "  size:      $(du -h "${OUT_LIB_DIR}/libllama.a" | cut -f1)"
echo "  commit:    ${CURRENT_REF}"
echo ""
echo "Next: zig build  (Wintermolt will pick up libllama.a automatically)"
