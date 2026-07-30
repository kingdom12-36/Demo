#!/bin/bash
# =============================================================================
#  Insert_susfs_into4.14kernel.sh
#  Patches KernelSU-Next (v3.1.0-legacy-susfs) + SusFS v2.0.0 into a
#  Linux 4.14 kernel tree, then optionally commits and pushes the result.
#
#  Tested against: kingdom12-36/Ocin4everKernel  (branch: Susfs)
#  KernelSU-Next : https://github.com/KernelSU-Next/KernelSU-Next
#                  tag v3.1.0-legacy-susfs  (legacy branch, Manual Hooks)
#  SusFS         : https://github.com/sidex15/susfs4ksu   tag v2.0.0
#
#  Usage:
#    ./Insert_susfs_into4.14kernel.sh [KERNEL_DIR] [TARGET_BRANCH]
#
#  Arguments (both optional):
#    KERNEL_DIR     – path to the kernel source root (default: current dir)
#    TARGET_BRANCH  – git branch to push to          (default: Susfs)
#
#  Environment variables you can override:
#    KERNELSU_TAG   – KernelSU-Next tag/commit  (default: v3.1.0-legacy-susfs)
#    SUSFS_TAG      – SusFS tag/commit           (default: v2.0.0)
#    PUSH           – set to "0" to skip git push (default: 1)
# =============================================================================
set -euo pipefail

# ── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ── Defaults ────────────────────────────────────────────────────────────────
KERNEL_DIR="${1:-$(pwd)}"
TARGET_BRANCH="${2:-Susfs}"
KERNELSU_TAG="${KERNELSU_TAG:-v3.1.0-legacy-susfs}"
SUSFS_TAG="${SUSFS_TAG:-v2.0.0}"
PUSH="${PUSH:-1}"

KERNELSU_OWNER="KernelSU-Next"
KERNELSU_REPO="KernelSU-Next"
SUSFS_OWNER="sidex15"
SUSFS_REPO="susfs4ksu"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Validate kernel tree ─────────────────────────────────────────────────────
[ -d "$KERNEL_DIR" ]           || error "Kernel directory not found: $KERNEL_DIR"
[ -f "$KERNEL_DIR/Makefile" ]  || error "Not a kernel tree (no Makefile): $KERNEL_DIR"

# Confirm this really is a 4.14 tree
KVER=$(grep -m1 '^VERSION' "$KERNEL_DIR/Makefile" | awk '{print $3}')
KPATCH=$(grep -m1 '^PATCHLEVEL' "$KERNEL_DIR/Makefile" | awk '{print $3}')
[ "$KVER" = "4" ] && [ "$KPATCH" = "14" ] || \
    warn "Expected 4.14, got ${KVER}.${KPATCH} — continuing anyway."

info "Kernel : ${KERNEL_DIR}  (${KVER}.${KPATCH})"
info "KSU-Next tag : ${KERNELSU_TAG}"
info "SusFS tag    : ${SUSFS_TAG}"
info "Push to      : ${TARGET_BRANCH}"
echo ""

# ── Locate drivers/ ──────────────────────────────────────────────────────────
if [ -d "$KERNEL_DIR/common/drivers" ]; then
    DRIVER_DIR="$KERNEL_DIR/common/drivers"
elif [ -d "$KERNEL_DIR/drivers" ]; then
    DRIVER_DIR="$KERNEL_DIR/drivers"
else
    error "'drivers/' directory not found inside $KERNEL_DIR"
fi
DRIVER_MAKEFILE="$DRIVER_DIR/Makefile"
DRIVER_KCONFIG="$DRIVER_DIR/Kconfig"

info "Drivers dir  : ${DRIVER_DIR}"

# ── Step 1 : Clean any previous KernelSU installation ───────────────────────
info "Step 1/6 – Cleaning previous KernelSU artefacts …"
[ -L "$DRIVER_DIR/kernelsu" ]  && rm  "$DRIVER_DIR/kernelsu"  && info "  Removed old kernelsu symlink"
[ -d "$DRIVER_DIR/kernelsu" ]  && rm -rf "$DRIVER_DIR/kernelsu" && info "  Removed old kernelsu directory"
[ -d "$KERNEL_DIR/KernelSU-Next" ] && rm -rf "$KERNEL_DIR/KernelSU-Next" && info "  Removed old KernelSU-Next clone"

# Remove previous entries from Makefile / Kconfig (idempotent)
sed -i '/obj-$(CONFIG_KSU).*+=.*kernelsu\//d'         "$DRIVER_MAKEFILE" 2>/dev/null || true
sed -i '/source "drivers\/kernelsu\/Kconfig"/d'        "$DRIVER_KCONFIG"  2>/dev/null || true

# ── Step 2 : Clone KernelSU-Next at the legacy-susfs tag ────────────────────
info "Step 2/6 – Cloning KernelSU-Next @ ${KERNELSU_TAG} …"
git clone --depth=1 \
    --branch "$KERNELSU_TAG" \
    "https://github.com/${KERNELSU_OWNER}/${KERNELSU_REPO}.git" \
    "$WORK_DIR/KernelSU-Next"

KSU_KERNEL_SRC="$WORK_DIR/KernelSU-Next/kernel"
[ -d "$KSU_KERNEL_SRC" ] || error "Expected 'kernel/' inside KernelSU-Next clone"

# Copy KSU kernel module into drivers/
cp -r "$KSU_KERNEL_SRC" "$DRIVER_DIR/kernelsu"
info "  Copied kernel/ → drivers/kernelsu"

# ── Step 3 : Wire KernelSU into the build system ────────────────────────────
info "Step 3/6 – Wiring KernelSU into Makefile & Kconfig …"

# Makefile — append after last meaningful line
grep -q "obj-\$(CONFIG_KSU).*+=.*kernelsu/" "$DRIVER_MAKEFILE" || \
    printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "$DRIVER_MAKEFILE"

# Kconfig — insert before 'endmenu'
grep -q 'source "drivers/kernelsu/Kconfig"' "$DRIVER_KCONFIG" || \
    sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "$DRIVER_KCONFIG"

info "  Makefile : $(grep 'kernelsu' "$DRIVER_MAKEFILE")"
info "  Kconfig  : $(grep 'kernelsu' "$DRIVER_KCONFIG")"

# ── Step 4 : Patch SusFS into the kernel fs/ tree ───────────────────────────
info "Step 4/6 – Cloning SusFS4KSU @ ${SUSFS_TAG} …"
git clone --depth=1 \
    --branch "$SUSFS_TAG" \
    "https://github.com/${SUSFS_OWNER}/${SUSFS_REPO}.git" \
    "$WORK_DIR/susfs4ksu"

SUSFS_DIR="$WORK_DIR/susfs4ksu"

# Locate patch files for 4.14 (naming varies across SusFS versions)
SUSFS_PATCH=""
for candidate in \
    "kernel_patches/50_add_susfs_in_kernel-4.14.patch" \
    "kernel_patches/50_add_susfs_in_kernel-4.x.patch" \
    "kernel_patches/add_susfs_in_kernel-4.14.patch" \
    "kernel_patches/add_susfs_in_kernel.patch"; do
    if [ -f "$SUSFS_DIR/$candidate" ]; then
        SUSFS_PATCH="$SUSFS_DIR/$candidate"
        info "  Found SusFS kernel patch : $candidate"
        break
    fi
done

# KSU-side SusFS patch
SUSFS_KSU_PATCH=""
for candidate in \
    "kernel_patches/next/0001-kernel-implement-susfs-for-ksu-next.patch" \
    "kernel_patches/0001-kernel-implement-susfs-for-ksu-next.patch" \
    "ksu_susfs_patch/0001-kernel-implement-susfs-for-ksu-next.patch"; do
    if [ -f "$SUSFS_DIR/$candidate" ]; then
        SUSFS_KSU_PATCH="$SUSFS_DIR/$candidate"
        info "  Found SusFS-KSU patch    : $candidate"
        break
    fi
done

# Apply KSU-side patch (goes into drivers/kernelsu)
if [ -n "$SUSFS_KSU_PATCH" ]; then
    info "  Applying KSU-side SusFS patch …"
    patch -p1 --directory="$DRIVER_DIR/kernelsu" < "$SUSFS_KSU_PATCH" || \
        warn "  KSU-side patch had rejects – check manually"
else
    warn "  KSU-side SusFS patch not found – copying fs files manually"
    # Fallback: copy susfs source files directly if no patch
    for f in susfs.h fs/susfs.c; do
        src="$SUSFS_DIR/$f"
        if [ -f "$src" ]; then
            dest_dir="$KERNEL_DIR/$(dirname "$f")"
            mkdir -p "$dest_dir"
            cp "$src" "$dest_dir/"
            info "    Copied: $f"
        fi
    done
fi

# Apply kernel-tree SusFS patch
if [ -n "$SUSFS_PATCH" ]; then
    info "  Applying kernel-tree SusFS patch …"
    patch -p1 --directory="$KERNEL_DIR" < "$SUSFS_PATCH" || \
        warn "  Kernel SusFS patch had rejects – check manually"
else
    warn "  Kernel SusFS patch not found – applying file-copy fallback"
    # Copy SusFS source files that normally live in fs/
    for candidate_fs in \
        "$SUSFS_DIR/fs/susfs.c" \
        "$SUSFS_DIR/linux/fs/susfs.c"; do
        if [ -f "$candidate_fs" ]; then
            cp "$candidate_fs" "$KERNEL_DIR/fs/susfs.c"
            info "    Copied fs/susfs.c"
            break
        fi
    done
    for candidate_h in \
        "$SUSFS_DIR/include/linux/susfs.h" \
        "$SUSFS_DIR/linux/include/linux/susfs.h"; do
        if [ -f "$candidate_h" ]; then
            mkdir -p "$KERNEL_DIR/include/linux"
            cp "$candidate_h" "$KERNEL_DIR/include/linux/susfs.h"
            info "    Copied include/linux/susfs.h"
            break
        fi
    done

    # Wire susfs into fs/Kconfig and fs/Makefile
    if [ -f "$KERNEL_DIR/fs/susfs.c" ]; then
        info "  Wiring susfs into fs/Kconfig and fs/Makefile …"
        grep -q 'SUSFS' "$KERNEL_DIR/fs/Kconfig" || \
            printf '\nconfig KSU_SUSFS\n\tbool "Enable SusFS for KernelSU"\n\tdepends on KSU\n\tdefault y\n\thelp\n\t  SusFS hides traces of KernelSU from apps.\n' \
            >> "$KERNEL_DIR/fs/Kconfig"
        grep -q 'susfs.o' "$KERNEL_DIR/fs/Makefile" || \
            printf '\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n' >> "$KERNEL_DIR/fs/Makefile"
    fi
fi

# ── Step 5 : Update defconfig and ksu.config ─────────────────────────────────
info "Step 5/6 – Updating kernel configs …"

enable_config() {
    local cfg="$1" file="$2"
    if [ -f "$file" ]; then
        # Remove any existing setting (commented-out or active) then set to y
        sed -i "/^# CONFIG_${cfg} is not set/d" "$file"
        sed -i "/^CONFIG_${cfg}=/d"             "$file"
        echo "CONFIG_${cfg}=y" >> "$file"
        info "  $(basename "$file") : CONFIG_${cfg}=y"
    fi
}

# ksu.config — toggle SusFS on and remove KPROBES path
KSU_CONFIG_FILE="$KERNEL_DIR/arch/arm64/configs/ksu.config"
if [ -f "$KSU_CONFIG_FILE" ]; then
    enable_config "KSU_SUSFS"             "$KSU_CONFIG_FILE"
    enable_config "KSU_SUSFS_SUS_PATH"    "$KSU_CONFIG_FILE"
    enable_config "KSU_SUSFS_SUS_MOUNT"   "$KSU_CONFIG_FILE"
    enable_config "KSU_SUSFS_SUS_KSTAT"   "$KSU_CONFIG_FILE"
    enable_config "KSU_SUSFS_SUS_OVERLAYFS" "$KSU_CONFIG_FILE"
    enable_config "KSU_SUSFS_TRY_UMOUNT"  "$KSU_CONFIG_FILE"
    enable_config "KSU_SUSFS_SPOOFER"     "$KSU_CONFIG_FILE"
    enable_config "KSU_SUSFS_OPEN_REDIRECT" "$KSU_CONFIG_FILE"

    # Prefer Manual hooks — disable KPROBES
    sed -i '/^CONFIG_KPROBES=/d'                    "$KSU_CONFIG_FILE"
    sed -i '/^CONFIG_HAVE_KPROBES=/d'               "$KSU_CONFIG_FILE"
    sed -i '/^CONFIG_KPROBE_EVENTS=/d'              "$KSU_CONFIG_FILE"
    sed -i '/^CONFIG_KSU_KPROBES_HOOK=/d'           "$KSU_CONFIG_FILE"
    echo "# CONFIG_KSU_KPROBES_HOOK is not set"   >> "$KSU_CONFIG_FILE"
    echo "# CONFIG_KPROBES is not set"             >> "$KSU_CONFIG_FILE"
    info "  KPROBES disabled — Manual hooks active"
else
    warn "  ksu.config not found at $KSU_CONFIG_FILE — skipping config update"
fi

# Also patch the main defconfig if it exists and contains KSU settings
for defcfg in \
    "$KERNEL_DIR/arch/arm64/configs/defconfig" \
    "$KERNEL_DIR/arch/arm64/configs/vendor/defconfig"; do
    if [ -f "$defcfg" ] && grep -q 'KSU' "$defcfg"; then
        enable_config "KSU_SUSFS" "$defcfg"
        info "  Patched defconfig : $defcfg"
    fi
done

# ── Step 6 : Commit and push ─────────────────────────────────────────────────
info "Step 6/6 – Committing changes …"
cd "$KERNEL_DIR"

git config user.name  "CI Bot"  2>/dev/null || true
git config user.email "ci@bot"  2>/dev/null || true

git add -A

COMMIT_MSG="kernel: integrate KernelSU-Next ${KERNELSU_TAG} + SusFS ${SUSFS_TAG}

- KernelSU-Next (legacy branch) copied into drivers/kernelsu
- drivers/Makefile and drivers/Kconfig updated
- SusFS ${SUSFS_TAG} patched into fs/ tree
- ksu.config: CONFIG_KSU_SUSFS=y, Manual Hooks (KPROBES disabled)
- SusFS feature flags enabled in ksu.config"

git commit -m "$COMMIT_MSG" || warn "Nothing new to commit — already up to date"

if [ "$PUSH" = "1" ]; then
    info "  Pushing to origin/${TARGET_BRANCH} …"
    git push origin HEAD:"$TARGET_BRANCH"
    info "Push complete."
else
    info "PUSH=0 — skipping push. Run 'git push origin HEAD:${TARGET_BRANCH}' manually."
fi

echo ""
info "All done. SusFS ${SUSFS_TAG} integrated with KernelSU-Next ${KERNELSU_TAG}."
echo ""
echo "  Next steps:"
echo "  1. Run the GitHub Actions build workflow to compile the kernel."
echo "  2. Verify no patch rejects in fs/ or drivers/kernelsu."
echo "  3. Check bootlog for susfs-related messages after flashing."
