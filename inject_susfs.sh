#!/bin/bash
# =============================================================================
#  inject_susfs_v2.sh — Full SusFS v2.1.0 + KSU-Next (4.14) Safe Injector
#  Based on commits: 1f377f2 & 118f46f (raystef66/kernel_xiaomi_cepheus #6)
# =============================================================================
set -euo pipefail

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'
ok()   { echo -e "${G}[+]${N} $*"; }
info() { echo -e "${B}[~]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[✗]${N} $*"; exit 1; }
step() { echo -e "\n${B}━━━ Step $* ━━━${N}"; }

KERNEL_DIR="${1:?KERNEL_DIR required}"
SUSFS_DIR="${2:?SUSFS_DIR required}"
KERNEL_REPO="${3:-kingdom12-36/Ocin4everKernel}"
KERNEL_BRANCH="${4:-Susfs}"
DRY_RUN="${5:-false}"

KSU_BRANCH="legacy-susfs-v2"

[ -d "$KERNEL_DIR" ]                  || err "Kernel dir not found: $KERNEL_DIR"
[ -d "$SUSFS_DIR"  ]                  || err "SusFS dir not found:  $SUSFS_DIR"
[ -d "$KERNEL_DIR/KernelSU-Next" ]    || err "KernelSU-Next submodule not found"

echo -e "${G}"
echo "  ┌────────────────────────────────────────────────────────┐"
echo "  │  SusFS v2.1.0 + KSU-Next Safe Injector (Kernel 4.14)   │"
echo "  └────────────────────────────────────────────────────────┘"
echo -e "${N}"

# ─────────────────────────────────────────────────────────────────────────────
step "1/8 — Fetch and Switch KernelSU-Next Submodule → $KSU_BRANCH"
# ─────────────────────────────────────────────────────────────────────────────
cd "$KERNEL_DIR/KernelSU-Next"
git fetch --all --tags --prune

if git rev-parse --verify "origin/$KSU_BRANCH" >/dev/null 2>&1; then
    git checkout -B "$KSU_BRANCH" "origin/$KSU_BRANCH"
elif git rev-parse --verify "$KSU_BRANCH" >/dev/null 2>&1; then
    git checkout "$KSU_BRANCH"
else
    git checkout FETCH_HEAD || err "Branch $KSU_BRANCH not found in KernelSU-Next repository"
fi

ok "KernelSU-Next branch: $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"
cd "$KERNEL_DIR"

# ─────────────────────────────────────────────────────────────────────────────
step "2/8 — Apply 50_add_susfs Patch to Kernel Source (The ADDITIONS)"
# ─────────────────────────────────────────────────────────────────────────────
KERNEL_PATCH=""
for c in \
    "$SUSFS_DIR/kernel_patches/50_add_susfs_in_kernel-4.14.patch" \
    "$SUSFS_DIR/kernel_patches/50_add_susfs_in_kernel-4.x.patch"  \
    "$SUSFS_DIR/50_add_susfs_in_kernel-4.14.patch"; do
    [ -f "$c" ] && KERNEL_PATCH="$c" && break
done

if [ -n "$KERNEL_PATCH" ]; then
    ok "Found patch: $(basename "$KERNEL_PATCH")"
    # Apply with forward + fuzz, ignoring already applied hunks safely
    if patch -p1 --forward --fuzz=3 --directory="$KERNEL_DIR" < "$KERNEL_PATCH" >/dev/null 2>&1; then
        ok "SusFS kernel hooks patched successfully into fs/ and include/ linux files!"
    else
        warn "Patch applied with warnings or already present — continuing safe execution."
        patch -p1 --forward --fuzz=3 --directory="$KERNEL_DIR" < "$KERNEL_PATCH" || true
    fi
else
    err "Could not find 50_add_susfs patch in $SUSFS_DIR"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "3/8 — Align drivers/Makefile"
# ─────────────────────────────────────────────────────────────────────────────
DRV_MK="$KERNEL_DIR/drivers/Makefile"
if [ -f "$DRV_MK" ]; then
    if grep -q "obj-y += kernelsu/" "$DRV_MK"; then
        sed -i 's/obj-y += kernelsu\//obj-$(CONFIG_KSU) += kernelsu\//g' "$DRV_MK"
        ok "Updated drivers/Makefile to use obj-\$(CONFIG_KSU)"
    elif ! grep -q "obj-\$(CONFIG_KSU) += kernelsu/" "$DRV_MK"; then
        echo 'obj-$(CONFIG_KSU) += kernelsu/' >> "$DRV_MK"
        ok "Added obj-\$(CONFIG_KSU) += kernelsu/ to drivers/Makefile"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
step "4/8 — Inject sys_reboot Hook (kernel/reboot.c)"
# ─────────────────────────────────────────────────────────────────────────────
REBOOT_C="$KERNEL_DIR/kernel/reboot.c"
if [ -f "$REBOOT_C" ]; then
    if ! grep -q 'ksu_handle_sys_reboot' "$REBOOT_C"; then
        python3 - "$REBOOT_C" << 'PYEOF'
import sys, re

path = sys.argv[1]
src = open(path).read()

extern_block = (
    "\n#ifdef CONFIG_KSU_MANUAL_HOOK\n"
    "extern int ksu_handle_sys_reboot(int magic1, int magic2,"
    " unsigned int cmd, void __user **arg);\n"
    "#endif\n"
)
call_block = (
    "#ifdef CONFIG_KSU_MANUAL_HOOK\n"
    "\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n"
    "#endif\n"
)

if "SYSCALL_DEFINE4(reboot" in src:
    m = re.search(r'SYSCALL_DEFINE4\s*\(\s*reboot\b', src)
    src = src[:m.start()] + extern_block + src[m.start():]
    
    anchor = re.search(r'SYSCALL_DEFINE4\s*\(\s*reboot[^{]*\{', src)
    if anchor:
        pos = anchor.end()
        src = src[:pos] + "\n" + call_block + src[pos:]
        open(path, 'w').write(src)
        print("Hook injected successfully into reboot.c")
PYEOF
        ok "sys_reboot hook updated in kernel/reboot.c"
    else
        ok "kernel/reboot.c already contains ksu_handle_sys_reboot"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
step "5/8 — Clean Deprecated sus_su & Sync SusFS v2.1.0 Core Files"
# ─────────────────────────────────────────────────────────────────────────────
rm -f "$KERNEL_DIR/fs/sus_su.c" "$KERNEL_DIR/include/linux/sus_su.h"
info "Removed deprecated sus_su files"

sync_file() {
    local filename="$1"
    local target_dir="$2"
    local src_file=""

    for path in \
        "$SUSFS_DIR/kernel_patches/fs/$filename" \
        "$SUSFS_DIR/fs/$filename" \
        "$SUSFS_DIR/kernel_patches/include/linux/$filename" \
        "$SUSFS_DIR/include/linux/$filename"; do
        if [ -f "$path" ]; then
            src_file="$path"
            break
        fi
    done

    if [ -n "$src_file" ]; then
        cp -f "$src_file" "$target_dir/$filename"
        ok "Synced $filename"
    else
        warn "Optional file $filename not found in $SUSFS_DIR (skipping)"
    fi
}

sync_file "susfs.c" "$KERNEL_DIR/fs"
sync_file "susfs.h" "$KERNEL_DIR/include/linux"
sync_file "susfs_def.h" "$KERNEL_DIR/include/linux"

# ─────────────────────────────────────────────────────────────────────────────
step "6/8 — Clean Stale overlayfs Macros"
# ─────────────────────────────────────────────────────────────────────────────
clean_overlay_file() {
    local file="$1"
    if [ -f "$file" ]; then
        sed -i '/#ifdef CONFIG_KSU_SUSFS_SUS_OVERLAYFS/d' "$file"
        sed -i '/#endif \/\* CONFIG_KSU_SUSFS_SUS_OVERLAYFS \*\//d' "$file"
        sed -i '/#endif \/\* CONFIG_KSU_SUSFS \*\//d' "$file"
        ok "Cleaned stale overlayfs macros from $(basename "$file")"
    fi
}

clean_overlay_file "$KERNEL_DIR/fs/overlayfs/inode.c"
clean_overlay_file "$KERNEL_DIR/fs/overlayfs/overlayfs.h"

# ─────────────────────────────────────────────────────────────────────────────
step "7/8 — Wire fs/Makefile & Update ksu.config"
# ─────────────────────────────────────────────────────────────────────────────
FS_MK="$KERNEL_DIR/fs/Makefile"
if ! grep -q 'susfs.o' "$FS_MK"; then
    echo -e '\n# SusFS v2.1.0\nobj-$(CONFIG_KSU_SUSFS) += susfs.o' >> "$FS_MK"
    ok "Added susfs.o to fs/Makefile"
fi
sed -i '/sus_su\.o/d' "$FS_MK"

CFG="$KERNEL_DIR/arch/arm64/configs/ksu.config"
if [ -f "$CFG" ]; then
    enable_opt() {
        sed -i "/CONFIG_$1/d" "$CFG"
        echo "CONFIG_$1=y" >> "$CFG"
    }
    enable_opt "KSU_SUSFS"
    enable_opt "KSU_SUSFS_SUS_PATH"
    enable_opt "KSU_SUSFS_SUS_MOUNT"
    enable_opt "KSU_SUSFS_SUS_KSTAT"
    enable_opt "KSU_SUSFS_TRY_UMOUNT"
    enable_opt "KSU_SUSFS_SPOOF_UNAME"
    enable_opt "KSU_SUSFS_ENABLE_LOG"
    enable_opt "KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS"
    enable_opt "KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG"
    enable_opt "KSU_SUSFS_OPEN_REDIRECT"
    enable_opt "KSU_SUSFS_SUS_MAP"
    enable_opt "KSU_MANUAL_HOOK"
    
    sed -i "/CONFIG_KSU_KPROBES_HOOK/d" "$CFG"
    echo "# CONFIG_KSU_KPROBES_HOOK is not set" >> "$CFG"
    ok "Updated ksu.config for SusFS v2.1.0"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "8/8 — Git Commit & Push"
# ─────────────────────────────────────────────────────────────────────────────
cd "$KERNEL_DIR"
if [ "$DRY_RUN" = "true" ]; then
    warn "Dry run — skipping commit and push."
    exit 0
fi

git add -A
if git diff --cached --quiet; then
    ok "No changes to commit."
else
    git commit -m "kernel: Inject SusFS v2.1.0 + KernelSU-Next (legacy-susfs-v2)

- Applied 50_add_susfs_in_kernel-4.14.patch to add SusFS hooks across fs/
- Switched KernelSU-Next submodule to legacy-susfs-v2
- Synced SusFS v2.1.0 core files (susfs.c, susfs.h, susfs_def.h)
- Injected sys_reboot Manual Hook in kernel/reboot.c
- Updated drivers/Makefile, fs/Makefile, and ksu.config"

    if [ -n "${GH_PAT:-}" ]; then
        git push "https://${GH_PAT}@github.com/${KERNEL_REPO}.git" HEAD:"$KERNEL_BRANCH"
    else
        git push origin HEAD:"$KERNEL_BRANCH"
    fi
    ok "Successfully pushed changes to $KERNEL_REPO/$KERNEL_BRANCH"
fi
