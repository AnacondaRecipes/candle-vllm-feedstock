#!/bin/bash
set -euxo pipefail

# ============================================================================
# candle-vllm build script
#
# Vendored git dependencies are downloaded as separate sources by conda-build
# and patched into Cargo.toml as local path dependencies.
#
# Dependency graph:
#   candle-vllm → candle-core, candle-nn (guoqingbao/candle fork)
#                → attention-rs (guoqingbao/attention.rs fork)
#                → range-checked, rustchatui (git-only crates)
#   candle-core → cudarc (guoqingbao/cudarc fork, via workspace)
#   attention-rs → cudarc (guoqingbao/cudarc fork)
#                → flashinfer (fetched at build time by cudaforge crate)
# ============================================================================

VENDOR_DIR="${SRC_DIR}/vendor"
MAIN_SRC="${SRC_DIR}/candle-vllm-src"

cd "${MAIN_SRC}"

# ============================================================================
# Step 0: Patch vendored sources
# ============================================================================

# Fix attention-rs: Metal code gated behind #[cfg(not(feature = "cuda"))] instead
# of #[cfg(feature = "metal")], causing CPU builds on Linux to fail.
patch -p1 -d "${VENDOR_DIR}/attention-rs" < "${RECIPE_DIR}/patches/attention-rs-fix-metal-cfg-gate.patch"

# ============================================================================
# Step 1: Patch Cargo.toml — replace git deps with local vendor paths
# ============================================================================

# candle-core (guoqingbao/candle fork workspace member)
sed -i.bak \
  's|candle-core = { git = "https://github.com/guoqingbao/candle.git", version = "0.8.3", rev = "5bed038" }|candle-core = { path = "'"${VENDOR_DIR}"'/candle/candle-core", version = "0.8.3" }|' \
  Cargo.toml

# candle-nn (same workspace)
sed -i.bak \
  's|candle-nn = { git = "https://github.com/guoqingbao/candle.git", version = "0.8.3", rev = "5bed038" }|candle-nn = { path = "'"${VENDOR_DIR}"'/candle/candle-nn", version = "0.8.3" }|' \
  Cargo.toml

# attention-rs
sed -i.bak \
  's|attention-rs = { git = "https://github.com/guoqingbao/attention.rs.git", version="0.4.3", rev = "c5f0de5" }|attention-rs = { path = "'"${VENDOR_DIR}"'/attention-rs", version = "0.4.3" }|' \
  Cargo.toml

# range-checked
sed -i.bak \
  's|range-checked = { git = "https://github.com/EricLBuehler/range-checked.git", version = "0.1.0" }|range-checked = { path = "'"${VENDOR_DIR}"'/range-checked", version = "0.1.0" }|' \
  Cargo.toml

# rustchatui
sed -i.bak \
  's|rustchatui = { git = "https://github.com/guoqingbao/rustchatui.git", rev="68caad9" }|rustchatui = { path = "'"${VENDOR_DIR}"'/rustchatui" }|' \
  Cargo.toml

rm -f Cargo.toml.bak

# ============================================================================
# Step 2: Add [patch] sections to override transitive git dependencies
# ============================================================================

# cudarc is referenced by candle workspace and attention-rs via git URL.
# Use Cargo's [patch] mechanism to redirect to local vendored copy.
cat >> Cargo.toml << 'PATCHEOF'

[patch."https://github.com/guoqingbao/cudarc.git"]
cudarc = { path = "VENDOR_DIR_PLACEHOLDER/cudarc" }

[patch."https://github.com/guoqingbao/candle.git"]
candle-core = { path = "VENDOR_DIR_PLACEHOLDER/candle/candle-core" }
candle-nn = { path = "VENDOR_DIR_PLACEHOLDER/candle/candle-nn" }
candle-kernels = { path = "VENDOR_DIR_PLACEHOLDER/candle/candle-kernels" }
PATCHEOF

# Replace placeholder with actual vendor path
sed -i.bak "s|VENDOR_DIR_PLACEHOLDER|${VENDOR_DIR}|g" Cargo.toml
rm -f Cargo.toml.bak

# ============================================================================
# Step 3: Pre-populate cudaforge cache for flashinfer (CUDA variant only)
# ============================================================================

if [[ "${gpu_variant}" == cuda* ]]; then
  # attention-rs uses the cudaforge crate which fetches flashinfer via git clone.
  # cudaforge caches repos at $CUDAFORGE_HOME/git/checkouts/{name}-{commit_prefix16}
  # Pre-populate cache to avoid network access during build.

  FLASHINFER_COMMIT="3bffdb76eef5fec462254dde67a7de0c4bcb9905"
  FLASHINFER_PREFIX="${FLASHINFER_COMMIT:0:16}"

  export CUDAFORGE_HOME="${SRC_DIR}/.cudaforge"
  CACHE_DIR="${CUDAFORGE_HOME}/git/checkouts/flashinfer-${FLASHINFER_PREFIX}"
  mkdir -p "${CACHE_DIR}"

  # Copy vendored flashinfer into the cache location
  cp -a "${VENDOR_DIR}/flashinfer/." "${CACHE_DIR}/"

  # Initialize as git repo — cudaforge checks git metadata
  (cd "${CACHE_DIR}" && git init && git add -A && git commit -m "vendored" --allow-empty) 2>/dev/null || true
fi

# ============================================================================
# Step 4: Configure build features based on variant
# ============================================================================

CARGO_FEATURES=""

if [[ "${gpu_variant}" == cuda* ]]; then
  CARGO_FEATURES="cuda,nccl,graph"

  # SM80 = Ampere (A100, A10G, A30) — good default for production
  export CUDA_COMPUTE_CAP=${CUDA_COMPUTE_CAP:-80}

  # CUDA paths for cudarc/nvcc discovery
  # cuda-driver-dev installs cuda.h to targets/x86_64-linux/include/, not include/
  # Symlink so cudarc's build.rs finds $CUDA_ROOT/include/cuda.h
  if [ -d "${PREFIX}/targets" ]; then
    for f in "${PREFIX}"/targets/*/include/*.h; do
      dir=$(dirname "$f")
      base=$(basename "$f")
      if [ ! -f "${PREFIX}/include/${base}" ]; then
        ln -sf "$f" "${PREFIX}/include/${base}"
      fi
    done
  fi

  export CUDA_ROOT="${PREFIX}"
  export CUDA_PATH="${PREFIX}"

  # CUDA 12.8+/13.x support GCC 14 — no special nvcc host compiler needed

  # Library search paths
  export LIBRARY_PATH="${PREFIX}/lib:${LIBRARY_PATH:-}"
  export LD_LIBRARY_PATH="${PREFIX}/lib:${LD_LIBRARY_PATH:-}"
fi

# ============================================================================
# Step 5: Rust build configuration
# ============================================================================

export CARGO_PROFILE_RELEASE_STRIP=symbols
export CARGO_PROFILE_RELEASE_LTO=fat

# macOS: reserve space for conda rpath fixup
if [[ "$(uname)" == "Darwin" ]]; then
  export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-headerpad_max_install_names"
fi

# OpenSSL for reqwest/hf-hub TLS
export OPENSSL_DIR="${PREFIX}"
export OPENSSL_INCLUDE_DIR="${PREFIX}/include"
export OPENSSL_LIB_DIR="${PREFIX}/lib"

# pkg-config paths
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# ============================================================================
# Step 6: Build and install
# ============================================================================

# Note: no --locked because upstream has no Cargo.lock
if [ -n "${CARGO_FEATURES}" ]; then
  cargo auditable install \
    --no-track \
    --verbose \
    --root "${PREFIX}" \
    --path . \
    --features "${CARGO_FEATURES}"
else
  cargo auditable install \
    --no-track \
    --verbose \
    --root "${PREFIX}" \
    --path .
fi
