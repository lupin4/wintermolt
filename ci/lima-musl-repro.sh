#!/bin/sh
# Deterministic local reproduction of the linMusl release lane
# (.github/workflows/linMusl-release.yml), for reviewers who cannot run the
# container on their own machine and as pre-merge evidence while the
# workflow_dispatch lane cannot run (GitHub only dispatches workflows that
# are on the default branch).
#
# The script runs the SAME alpine:3.23 container steps, in workflow order,
# with the same pins:
#   - stage the committed tree (git archive: no .git dir, no caches, no
#     build output, no uncommitted edits, and a tar format the alpine
#     container's busybox tar extracts byte-exact)
#   - pull alpine:3.23 by tag and print the digest the tag resolved to, so a
#     re-run is comparable at the image level
#   - install the same apk package set
#   - install Zig 0.16.0 with the same per-arch sha256 verification as the
#     workflow matrix, downloading from ziglang.org only behind that pin
#   - build with the same flags: -Doptimize=ReleaseSmall
#     -Dcpu=<baseline|x86_64_v3> -Dstrip=true
#   - run the same tests, the same binary checks, and the same smoke test
#   - finish with the SVE / zmm / RUNPATH / GLIBC_ verdicts and the binary
#     sha256
#
# Two runner modes, selected with --runner lima|docker or auto-detected:
#   - lima:   drive the existing ci-local Lima VM (limactl shell ci-local),
#             the default on macOS where limactl is installed
#   - docker: drive the local docker daemon directly, the default on a
#             native Linux host
# The x86_64 lane runs the amd64 Alpine image under emulation: Rosetta binfmt
# inside the ci-local VM in lima mode, so both matrix lanes are reproducible
# on one arm64 Mac; native hardware in docker mode.
#
# Portability: the host side uses no grep (some hosts ship a broken grep
# shim), and all build steps and checks run inside the alpine container where
# busybox grep is intact. Network use is exactly the workflow's: the
# alpine:3.23 image pull, the apk repositories pinned by that image, and the
# ziglang.org tarball behind its pinned sha256. Nothing else is fetched.
#
# Usage: ci/lima-musl-repro.sh [--runner lima|docker] [arm64|x86_64]
#        (default lane: arm64)

set -eu

VM=ci-local

usage() {
  echo "usage: $0 [--runner lima|docker] [arm64|x86_64]" >&2
  exit 2
}

# --- Arguments: exactly one lane plus an optional explicit runner. --------
# A runner override must never be guessed, and a repeated lane or a typo is a
# usage error, not a silently ignored extra flag.
arch=
runner=auto
while [ $# -gt 0 ]; do
  case "$1" in
    --runner)
      [ $# -ge 2 ] || usage
      runner=$2
      shift 2
      ;;
    arm64|x86_64)
      [ -z "$arch" ] || usage
      arch=$1
      shift
      ;;
    *)
      usage
      ;;
  esac
done
arch=${arch:-arm64}
case "$runner" in
  auto|lima|docker) ;;
  *) usage ;;
esac

# --- Per-lane pins, mirroring the workflow matrix exactly. ----------------
case "$arch" in
  arm64)
    # Native lane: the ci-local VM itself is aarch64.
    platform=linux/arm64
    cpu=baseline
    zig_arch=aarch64
    # sha256 of zig-aarch64-linux-0.16.0.tar.xz, from the 0.16.0 entry of
    # https://ziglang.org/download/index.json.
    zig_sha256=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17
    ;;
  x86_64)
    # Emulated under Rosetta in lima mode, native hardware in docker mode.
    platform=linux/amd64
    cpu=x86_64_v3
    zig_arch=x86_64
    zig_sha256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
    ;;
esac

# --- Runner selection. ----------------------------------------------------
# limactl is the lima runner, but only where it is both installed and the
# right tool (macOS); a native Linux host talks to its own docker daemon.
if [ "$runner" = auto ]; then
  if command -v limactl >/dev/null 2>&1 && [ "$(uname -s)" = Darwin ]; then
    runner=lima
  else
    runner=docker
  fi
fi

# --- Locate this checkout. ------------------------------------------------
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
# git is required twice below (recording the commit, archiving its tree), so
# fail fast with a clear message when it is missing.
if ! command -v git >/dev/null 2>&1; then
  echo "FAIL: git is required to stage the committed tree" >&2
  exit 1
fi
# Record which source this repro builds, so a captured log names the exact
# commit its verdicts belong to.
commit=$(git -C "$repo" rev-parse --verify HEAD)

# --- Lima VM lifecycle (lima runner only). --------------------------------
# Start the VM if it is not running; remember whether this run owns it, so the
# teardown leaves untouched a VM that was already up for other work.
started_vm=0
if [ "$runner" = lima ]; then
  if [ "$(limactl list --format '{{.Status}}' "$VM")" != Running ]; then
    started_vm=1
    limactl start --tty=false "$VM"
  fi
fi

# --- Host-side staging. ---------------------------------------------------
# Stage the committed tree with git archive: the repro must build exactly what
# the workflow would check out, not a .git dir, a compiler cache, a stale
# zig-out, or uncommitted local edits. git archive also emits a plain ustar
# stream, which the busybox tar inside the alpine container extracts
# byte-exact -- a macOS bsdtar archive does not survive that handoff (its
# sparse/PAX entries come out as GNUSparseFile.0 and silently lose files).
stage=$(mktemp -d "${TMPDIR:-/tmp}/wintermolt-musl-repro.XXXXXXXX")
cleanup() {
  # Remove the staged source and, in lima mode, the two files copied into the
  # VM (both owned by this run's user); stop the VM only if this run started
  # it. Build output lives inside the container, which the inner script
  # always removes, so no root-owned files are ever left behind anywhere.
  if [ "$runner" = lima ]; then
    limactl shell "$VM" -- rm -f /tmp/wintermolt-musl.tar \
      /tmp/wintermolt-musl-inner.sh >/dev/null 2>&1 || true
  fi
  rm -rf "$stage"
  if [ "$started_vm" -eq 1 ]; then
    limactl stop "$VM" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

git -C "$repo" archive --format=tar -o "$stage/src.tar" HEAD

cat > "$stage/inner.sh" <<'INNER'
#!/bin/sh
# Runs wherever the docker daemon lives: inside the ci-local VM in lima mode,
# or directly on the Linux host in docker mode. Every block below mirrors one
# step of .github/workflows/linMusl-release.yml for one matrix lane, in the
# workflow's order, with the workflow's pins. The host running this inner
# script only needs sh and docker; every build step and every check runs
# inside the alpine container.
set -eu

# Six arguments, all supplied by the outer ci/lima-musl-repro.sh; assert the
# full set so a partial invocation fails here instead of mid-build.
[ $# -eq 6 ] || {
  echo "usage: inner.sh <arch_label> <zig_arch> <cpu> <zig_sha256> <platform> <src_tar>" >&2
  exit 2
}
arch_label=$1   # arm64|x86_64: the workflow matrix entry being reproduced
zig_arch=$2     # aarch64|x86_64: the ziglang.org tarball name segment
cpu=$3          # baseline|x86_64_v3: the workflow's -Dcpu for this lane
zig_sha256=$4   # pinned sha256 of the Zig tarball for this lane
platform=$5     # linux/arm64|linux/amd64: the container platform
src_tar=$6      # staged source tarball, produced by the outer script

image=alpine:3.23
name=wintermolt-musl-repro

# The container is the only thing this run creates that is not user-owned, so
# the EXIT trap removes it on both success and failure; nothing is left
# behind anywhere after the run.
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT INT TERM

# A stale container from an aborted run must not leak into this one: the
# repro is only evidence if it starts clean.
docker rm -f "$name" >/dev/null 2>&1 || true

# Pull the workflow's image by tag, then record the digest the tag resolved
# to. The tag is the pin (the workflow pins the same way); the printed digest
# is what makes two runs comparable at the image level.
docker pull --platform "$platform" "$image" >/dev/null
digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$image")
echo "image: $image (tag-pinned), resolved digest: $digest"

# Same container invocation as the workflow's "Start the alpine:3.23 build
# container" step, plus --platform so the x86_64 lane gets the amd64 image.
# The source is copied in with docker cp rather than a bind mount: the build
# then owns its whole filesystem, and teardown is one docker rm.
docker run -d --name "$name" --platform "$platform" "$image" sleep infinity >/dev/null
docker cp "$src_tar" "$name":/tmp/src.tar
docker exec "$name" sh -c 'mkdir -p /w && tar -xf /tmp/src.tar -C /w'

# Same package set as the workflow's "Install build and check tools" step.
docker exec "$name" apk add --no-cache \
  build-base curl curl-dev sqlite-dev pkgconf \
  binutils file xz tar

# Same Zig install as the workflow's "Install Zig 0.16.0 (sha256-verified)"
# step: download, verify the pinned sha256, only then extract.
docker exec -w /w -e ZIG_SHA256="$zig_sha256" -e ZIG_ARCH="$zig_arch" \
  -i "$name" sh -s <<'EOS'
set -eu
arch=$(uname -m)
zigdir="/opt/zig-${arch}-linux-0.16.0"
# The container arch must match the requested lane: a wrong platform would
# otherwise download a different tarball than the one pinned for this lane.
[ "$arch" = "$ZIG_ARCH" ]
# The official Linux Zig build is a static binary: it runs on musl.
curl -fsSL -o /tmp/zig.tar.xz \
  "https://ziglang.org/download/0.16.0/zig-${arch}-linux-0.16.0.tar.xz"
# Verify before anything extracts or runs the tarball.
echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c -
tar -C /opt -xf /tmp/zig.tar.xz
ln -sf "$zigdir/zig" /usr/local/bin/zig
zig version
EOS

# Same build and test steps as the workflow.
docker exec -w /w "$name" zig build -Doptimize=ReleaseSmall -Dcpu="$cpu" -Dstrip=true --summary all
docker exec -w /w "$name" zig build test --summary all

# Same binary checks as the workflow's "Check the binary" step. Every count is
# printed so the log carries the measured evidence, not just the pass/fail.
docker exec -w /w -i "$name" sh -s <<'EOS'
set -eu
B=zig-out/bin/wintermolt
arch=$(uname -m)
file "$B"
ls -l "$B"
sha256sum "$B"

if ! readelf -l "$B" | grep -q 'ld-musl-.*\.so\.1'; then
  echo "FAIL: interpreter is not the musl loader"
  exit 1
fi
if readelf -V "$B" | grep -q 'GLIBC_'; then
  echo "FAIL: the binary still carries GLIBC_ version needs"
  exit 1
fi
if readelf --dyn-syms "$B" | grep -q 'GLIBC_'; then
  echo "FAIL: the binary still imports GLIBC_ symbols"
  exit 1
fi
if strings "$B" | grep -q 'GLIBC_'; then
  echo "FAIL: GLIBC_ strings remain in the binary"
  exit 1
fi
echo "OK: musl loader, zero GLIBC_ imports"

# The release checks the linX86 lane records (41b974a), carried to the musl
# lane. -Dcpu= is what guarantees them; these checks are what catch a
# regression.
if [ "$arch" = aarch64 ]; then
  # SVE: generic aarch64 (the Pi boards' baseline) has none, so a single SVE
  # instruction makes the binary SIGILL there.
  sve=$(objdump -d "$B" | grep -cE '\b(ptrue|movprfx|whilelo|ld1d|st1d|cntd)\b' || true)
  echo "sve (SVE) instructions: $sve"
  [ "$sve" -eq 0 ]
  echo "OK: arm64 carries zero SVE instructions"
fi
if [ "$arch" = x86_64 ]; then
  # zmm: AVX-512 sits above this lane's x86_64_v3 floor.
  zmm=$(objdump -d "$B" | grep -c zmm || true)
  echo "zmm (AVX-512) instructions: $zmm"
  [ "$zmm" -eq 0 ]
  echo "ymm (AVX2) instructions: $(objdump -d "$B" | grep -c ymm || true)"
  echo "OK: x86_64 carries zero zmm instructions"
fi
# No embedded library search path: the musl deps must resolve from the
# system, not from a builder-local rpath.
if readelf -d "$B" | grep -E 'RUNPATH|RPATH'; then
  echo "FAIL: the binary carries a RUNPATH/RPATH"
  exit 1
fi
echo "OK: no RUNPATH/RPATH"

echo "DT_NEEDED:"
readelf -d "$B" | grep NEEDED
EOS

# Same smoke test as the workflow's "Smoke test on musl (no gcompat)" step.
docker exec -w /w -i "$name" sh -s <<'EOS'
set -eu
B=zig-out/bin/wintermolt
"$B" --version
printf '/stats\n/quit\n' | "$B"
EOS

# Final verdict. Fail-fast above means reaching this line already proves every
# check passed: the SVE/zmm counts were asserted 0, no RUNPATH/RPATH, and no
# GLIBC_ anywhere. The binary sha256 is re-printed so the last lines of the
# log are the complete reproducible evidence.
bin_sha256=$(docker exec -w /w "$name" sha256sum zig-out/bin/wintermolt | cut -d ' ' -f 1)
echo "VERDICT: $arch_label lane reproduced on $image, digest $digest"
echo "VERDICT: Zig 0.16.0 tarball verified against pinned sha256 $zig_sha256"
echo "VERDICT: SVE/zmm count 0, no RUNPATH/RPATH, no GLIBC_, musl loader"
echo "VERDICT: binary sha256 $bin_sha256"
INNER

# --- Hand the staged source and inner script to the runner. ---------------
echo "runner: $runner, lane: $arch, source commit: $commit"
if [ "$runner" = lima ]; then
  limactl copy "$stage/src.tar" "$VM":/tmp/wintermolt-musl.tar
  limactl copy "$stage/inner.sh" "$VM":/tmp/wintermolt-musl-inner.sh
  limactl shell "$VM" -- sh /tmp/wintermolt-musl-inner.sh \
    "$arch" "$zig_arch" "$cpu" "$zig_sha256" "$platform" /tmp/wintermolt-musl.tar
else
  sh "$stage/inner.sh" \
    "$arch" "$zig_arch" "$cpu" "$zig_sha256" "$platform" "$stage/src.tar"
fi
