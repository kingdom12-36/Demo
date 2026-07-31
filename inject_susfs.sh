#!/bin/bash
# =============================================================================
#  inject_susfs_v2.sh — Implementation for SusFS v2.1.0 + KSU-Next (4.14)
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
step "1/7 — Commit 1f377f2: Switch Submodule to $KSU_BRANCH"
# ─────────────────────────────────────────────────────────────────────────────
cd "$KERNEL_DIR/KernelSU-Next"
git fetch origin
git checkout "$KSU_BRANCH" || git checkout -b "$KSU_BRANCH" "origin/$KSU_BRANCH"
git pull origin "$KSU_BRANCH" || true
ok "KernelSU-Next branch: $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"
cd "$KERNEL_DIR"

# ─────────────────────────────────────────────────────────────────────────────
step "2/7 — Commit 1f377f2: Align drivers/Makefile"
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
step "3/7 — Commit 1f377f2: Inject sys_reboot Hook (kernel/reboot.c)"
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
step "4/7 — Commit 118f46f: Clean Deprecated sus_su & Sync SusFS v2.1.0 Core"
# ─────────────────────────────────────────────────────────────────────────────
# 1. إزالة ملفات sus_su إن وجدت
rm -f "$KERNEL_DIR/fs/sus_su.c" "$KERNEL_DIR/include/linux/sus_su.h"
info "Removed deprecated sus_su files if present"

# 2. نسخ ملفات Core الخاصة بـ SusFS v2.1.0
cp -f "$SUSFS_DIR/kernel_patches/fs/susfs.c" "$KERNEL_DIR/fs/susfs.c" 2>/dev/null || \
cp -f "$SUSFS_DIR/fs/susfs.c" "$KERNEL_DIR/fs/susfs.c"

cp -f "$SUSFS_DIR/kernel_patches/include/linux/susfs.h" "$KERNEL_DIR/include/linux/susfs.h" 2>/dev/null || \
cp -f "$SUSFS_DIR/include/linux/susfs.h" "$KERNEL_DIR/include/linux/susfs.h"

cp -f "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" "$KERNEL_DIR/include/linux/susfs_def.h" 2>/dev/null || \
cp -f "$SUSFS_DIR/include/linux/susfs_def.h" "$KERNEL_DIR/include/linux/susfs_def.h"

ok "Synced SusFS v2.1.0 core files (susfs.c, susfs.h, susfs_def.h)"

# ─────────────────────────────────────────────────────────────────────────────
step "5/7 — Commit 118f46f: Clean Stale overlayfs Macros"
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
step "6/7 — Wire fs/Makefile & Update ksu.config"
# ─────────────────────────────────────────────────────────────────────────────
FS_MK="$KERNEL_DIR/fs/Makefile"
if ! grep -q 'susfs.o' "$FS_MK"; then
    echo -e '\n# SusFS v2.1.0\nobj-$(CONFIG_KSU_SUSFS) += susfs.o' >> "$FS_MK"
    ok "Added susfs.o to fs/Makefile"
fi
sed -i '/sus_su\.o/d' "$FS_MK" # مسح أي إشارة قديمة لـ sus_su.o

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
step "7/7 — Git Commit & Push"
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
    git commit -m "kernel: Update KernelSU-Next to v3.1.0-legacy-susfs-v2 with SUSFS v2.1.0

- Switch KernelSU-Next submodule to legacy-susfs-v2 branch
- Implement SusFS v2.1.0 core files (susfs.c, susfs.h, susfs_def.h)
- Remove deprecated sus_su feature and stale overlayfs blocks
- Add sys_reboot Manual Hook in kernel/reboot.c
- Align drivers/Makefile and fs/Makefile Kbuild rules"

    if [ -n "${GH_PAT:-}" ]; then
        git push "https://${GH_PAT}@github.com/${KERNEL_REPO}.git" HEAD:"$KERNEL_BRANCH"
    else
        git push origin HEAD:"$KERNEL_BRANCH"
    fi
    ok "Successfully pushed changes to $KERNEL_REPO/$KERNEL_BRANCH"
fi
