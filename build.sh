#!/usr/bin/env bash
set -euo pipefail

# ── Config (overridable via env) ──────────────────────────────────────────────
KERNEL_REPO="https://github.com/Nevuly/WSL2-Linux-Kernel-Rolling.git"
PATCH_BASE="https://github.com/CachyOS/kernel-patches.git"
OUTDIR="release-artefacts"

# ── 1. Install dependencies ───────────────────────────────────────────────────
echo ">>> [1/6] Installing build dependencies..."
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
  build-essential bc bison flex libssl-dev libelf-dev \
  libncurses-dev pahole dwarves python3 \
  clang lld llvm \
  cpio curl git wget zip

# ── 2. Clone kernel source ────────────────────────────────────────────────────
echo ">>> [2/6] Cloning WSL2 kernel source..."
git clone -b "wsl-6.19-rolling" --single-branch --depth=1 https://github.com/CachyOS/kernel-patches.git kernel

KERNEL_VERSION=$(make -C kernel kernelversion 2>/dev/null)
echo "$KERNEL_VERSION" > kernel-version.txt
echo "    Kernel version: $KERNEL_VERSION"

# ── 3. Download patches ───────────────────────────────────────────────────────
echo ">>> [3/6] Downloading CachyOS patches..."
mkdir -p patches

curl -fsSL "$PATCH_BASE/all/0001-cachyos-base-all.patch" \
  -o patches/0001-cachyos-base-all.patch

curl -fsSL "$PATCH_BASE/misc/0001-clang-polly.patch" \
  -o patches/0002-clang-polly.patch

curl -fsSL "$PATCH_BASE/sched/0001-bore-cachy.patch" \
  -o patches/0003-bore-cachy.patch

# ── 4. Apply patches ──────────────────────────────────────────────────────────
echo ">>> [4/6] Applying patches..."
for patch in patches/*.patch; do
  echo "    Applying: $patch"
  git -C kernel apply --verbose "../$patch"
done

# ── 5. Configure kernel ───────────────────────────────────────────────────────
echo ">>> [5/6] Configuring kernel..."
pushd kernel > /dev/null

if [ -f Microsoft/config-wsl ]; then
  echo "    Using Microsoft/config-wsl as base config"
  cp Microsoft/config-wsl .config
else
  echo "    Falling back to defconfig"
  make LLVM=1 defconfig
fi

scripts/config --enable  CONFIG_SCHED_BORE        || true
scripts/config --enable  CONFIG_POLLY             || true
scripts/config --disable CONFIG_DEBUG_INFO        || true
scripts/config --set-str CONFIG_LOCALVERSION "-cachy-wsl2"

make LLVM=1 olddefconfig

popd > /dev/null

# ── 6. Build ──────────────────────────────────────────────────────────────────
echo ">>> [6/6] Building kernel ($(nproc) threads)..."
make -C kernel \
  LLVM=1 \
  LLVM_IAS=1 \
  LD=ld.lld \
  KCFLAGS="-O2 -mllvm -polly" \
  -j"$(nproc)" \
  bzImage modules

# ── Package artefacts ─────────────────────────────────────────────────────────
echo ">>> Packaging artefacts..."
mkdir -p "$OUTDIR"

cp kernel/arch/x86/boot/bzImage "$OUTDIR/bzImage"

make -C kernel \
  LLVM=1 \
  INSTALL_MOD_PATH="../$OUTDIR/modules-staging" \
  modules_install

tar -C "$OUTDIR/modules-staging" \
    -czf "$OUTDIR/kernel-modules.tar.gz" .

cat > "$OUTDIR/README.md" <<'EOF'
## Installation

1. Copy `bzImage` to a permanent path, e.g. `C:\bzImage`.
2. Add (or update) `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
kernel=C:\\bzImage
```

3. Restart WSL2: `wsl --shutdown && wsl`
EOF

echo ">>> Done! Artefacts written to $OUTDIR/"
ls -lh "$OUTDIR/"
