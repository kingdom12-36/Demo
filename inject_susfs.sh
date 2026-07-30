#!/bin/bash
# =============================================================================
#  inject_susfs.sh
#  يحقن KernelSU-Next (legacy-susfs) + SusFS (kernel-4.14) في شجرة
#  الكيرنل ويدفش كوميت واحدة على الريبو المستهدف.
#
#  الاستخدام:
#    ./inject_susfs.sh <KERNEL_DIR> <SUSFS_DIR> [KERNEL_REPO] [KERNEL_BRANCH] [DRY_RUN]
#
#  المتغيرات:
#    KERNEL_DIR    – مسار clone الكيرنل المحلي
#    SUSFS_DIR     – مسار clone susfs4ksu المحلي
#    KERNEL_REPO   – kingdom12-36/Ocin4everKernel  (للـ push)
#    KERNEL_BRANCH – Susfs
#    DRY_RUN       – true = بس اعرض التغييرات، ما تدفش
#    KSU_TAG       – v3.1.0-legacy-susfs
# =============================================================================
set -euo pipefail

# ── ألوان ─────────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'
ok()   { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[✗]${N} $*"; exit 1; }

# ── Arguments ─────────────────────────────────────────────────────────────────
KERNEL_DIR="${1:?KERNEL_DIR required}"
SUSFS_DIR="${2:?SUSFS_DIR required}"
KERNEL_REPO="${3:-kingdom12-36/Ocin4everKernel}"
KERNEL_BRANCH="${4:-Susfs}"
DRY_RUN="${5:-false}"
KSU_TAG="${KSU_TAG:-v3.1.0-legacy-susfs}"

[ -d "$KERNEL_DIR" ] || err "Kernel dir not found: $KERNEL_DIR"
[ -d "$SUSFS_DIR"  ] || err "SusFS dir not found: $SUSFS_DIR"

ok "Kernel  : $KERNEL_DIR"
ok "SusFS   : $SUSFS_DIR"
ok "Target  : $KERNEL_REPO @ $KERNEL_BRANCH"
ok "KSU tag : $KSU_TAG"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
#  STEP 1 — تحديث submodule KernelSU-Next
# ──────────────────────────────────────────────────────────────────────────────
ok "Step 1/5 — Updating KernelSU-Next submodule to $KSU_TAG"
cd "$KERNEL_DIR/KernelSU-Next"
git fetch --tags origin
git checkout "$KSU_TAG"
ok "  KSU-Next is now at: $(git describe --tags --always)"
cd "$KERNEL_DIR"

# ──────────────────────────────────────────────────────────────────────────────
#  STEP 2 — نسخ ملفات SusFS
# ──────────────────────────────────────────────────────────────────────────────
ok "Step 2/5 — Copying SusFS kernel files"

# susfs.c
SUSFS_C=""
for c in \
    "$SUSFS_DIR/fs/susfs.c" \
    "$SUSFS_DIR/kernel_patches/fs/susfs.c"; do
    [ -f "$c" ] && SUSFS_C="$c" && break
done

if [ -n "$SUSFS_C" ]; then
    cp "$SUSFS_C" "$KERNEL_DIR/fs/susfs.c"
    ok "  Copied susfs.c → fs/susfs.c"
else
    warn "  susfs.c not found — will rely on patch"
fi

# susfs.h
SUSFS_H=""
for h in \
    "$SUSFS_DIR/include/linux/susfs.h" \
    "$SUSFS_DIR/kernel_patches/include/linux/susfs.h"; do
    [ -f "$h" ] && SUSFS_H="$h" && break
done

if [ -n "$SUSFS_H" ]; then
    mkdir -p "$KERNEL_DIR/include/linux"
    cp "$SUSFS_H" "$KERNEL_DIR/include/linux/susfs.h"
    ok "  Copied susfs.h → include/linux/susfs.h"
else
    warn "  susfs.h not found — will rely on patch"
fi

# ──────────────────────────────────────────────────────────────────────────────
#  STEP 3 — تطبيق الـ patches
# ──────────────────────────────────────────────────────────────────────────────
ok "Step 3/5 — Applying patches"

apply_patch() {
    local label="$1" patch="$2" target_dir="$3"
    if [ -z "$patch" ]; then
        warn "  No patch found for: $label"
        return
    fi
    ok "  Applying $label: $(basename "$patch")"
    if patch -p1 --forward --fuzz=3 --directory="$target_dir" < "$patch"; then
        ok "  $label patch applied cleanly"
    else
        warn "  $label patch had rejects — check .rej files in $target_dir"
    fi
}

# Kernel-tree patch (fs/, include/)
KERNEL_PATCH=$(find "$SUSFS_DIR/kernel_patches" -maxdepth 1 \
    -name "50_add_susfs_in_kernel-4.14*" \
    -o -name "50_add_susfs_in_kernel-4.x*" \
    -o -name "50_add_susfs*4.14*" 2>/dev/null | head -1)
apply_patch "kernel-tree SusFS" "$KERNEL_PATCH" "$KERNEL_DIR"

# KSU-side patch (KernelSU-Next/kernel/)
KSU_PATCH=$(find "$SUSFS_DIR/kernel_patches" -maxdepth 4 \
    \( -name "*ksu-next*" -o -name "*implement-susfs*" \) \
    -name "*.patch" 2>/dev/null | head -1)
apply_patch "KSU-side SusFS" "$KSU_PATCH" "$KERNEL_DIR/KernelSU-Next/kernel"

# ──────────────────────────────────────────────────────────────────────────────
#  STEP 4 — fs/Makefile + fs/Kconfig
# ──────────────────────────────────────────────────────────────────────────────
ok "Step 4/5 — Wiring SusFS into fs/Makefile and fs/Kconfig"

# fs/Makefile
FS_MK="$KERNEL_DIR/fs/Makefile"
if grep -q 'susfs.o' "$FS_MK"; then
    ok "  fs/Makefile already wired"
else
    printf '\n# SusFS\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n' >> "$FS_MK"
    ok "  Added susfs.o to fs/Makefile"
fi

# fs/Kconfig — كتابة block كامل في temp file وinsert
FS_KCONFIG="$KERNEL_DIR/fs/Kconfig"
if grep -q 'KSU_SUSFS' "$FS_KCONFIG"; then
    ok "  fs/Kconfig already has KSU_SUSFS"
else
    KCONFIG_BLOCK='
config KSU_SUSFS
	bool "Enable SusFS for KernelSU"
	depends on KSU
	default y if KSU
	help
	  Hides KernelSU traces from apps using SusFS filesystem hooks.
'
    # أضف قبل آخر endmenu
    TMPFILE=$(mktemp)
    awk -v block="$KCONFIG_BLOCK" '
        /^endmenu/ && !done { print block; done=1 }
        { print }
    ' "$FS_KCONFIG" > "$TMPFILE"
    mv "$TMPFILE" "$FS_KCONFIG"
    ok "  Added KSU_SUSFS config to fs/Kconfig"
fi

# ──────────────────────────────────────────────────────────────────────────────
#  STEP 5 — ksu.config
# ──────────────────────────────────────────────────────────────────────────────
ok "Step 5/5 — Updating ksu.config"
CFG="$KERNEL_DIR/arch/arm64/configs/ksu.config"
[ -f "$CFG" ] || err "ksu.config not found at $CFG"

enable_opt() {
    local opt="$1"
    sed -i "/^# CONFIG_${opt} is not set/d" "$CFG"
    sed -i "/^CONFIG_${opt}=/d"             "$CFG"
    echo "CONFIG_${opt}=y" >> "$CFG"
    ok "  CONFIG_${opt}=y"
}

disable_opt() {
    local opt="$1"
    sed -i "/^CONFIG_${opt}=.*/d"           "$CFG"
    sed -i "/^# CONFIG_${opt} is not set/d" "$CFG"
    echo "# CONFIG_${opt} is not set"      >> "$CFG"
    ok "  CONFIG_${opt} disabled (Manual Hooks)"
}

enable_opt  KSU_SUSFS
enable_opt  KSU_SUSFS_SUS_PATH
enable_opt  KSU_SUSFS_SUS_MOUNT
enable_opt  KSU_SUSFS_SUS_KSTAT
enable_opt  KSU_SUSFS_SUS_OVERLAYFS
enable_opt  KSU_SUSFS_TRY_UMOUNT
enable_opt  KSU_SUSFS_SPOOFER
enable_opt  KSU_SUSFS_OPEN_REDIRECT
enable_opt  KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
enable_opt  KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
disable_opt KSU_KPROBES_HOOK
disable_opt KPROBES

echo ""
ok "=== Final ksu.config ==="
cat "$CFG"

# ──────────────────────────────────────────────────────────────────────────────
#  COMMIT + PUSH
# ──────────────────────────────────────────────────────────────────────────────
echo ""
ok "=== Git status ==="
cd "$KERNEL_DIR"
git status --short

if [ "$DRY_RUN" = "true" ]; then
    warn "Dry run — no commit/push performed."
    exit 0
fi

git add -A

if git diff --cached --quiet; then
    ok "Nothing to commit — already up to date."
    exit 0
fi

git commit -m "kernel: inject KernelSU-Next ${KSU_TAG} + SusFS (kernel-4.14)

- KernelSU-Next submodule updated to ${KSU_TAG} (legacy-susfs branch)
- fs/susfs.c: SusFS core implementation
- include/linux/susfs.h: SusFS header
- fs/Makefile: obj-\$(CONFIG_KSU_SUSFS) += susfs.o
- fs/Kconfig: KSU_SUSFS config option added
- ksu.config: CONFIG_KSU_SUSFS=y + all feature flags enabled
- ksu.config: KPROBES disabled, Manual Hooks active"

# GH_PAT يجي من الـ environment
if [ -n "${GH_PAT:-}" ]; then
    git push \
        "https://${GH_PAT}@github.com/${KERNEL_REPO}.git" \
        HEAD:"$KERNEL_BRANCH"
    ok "Pushed to $KERNEL_REPO/$KERNEL_BRANCH"
else
    git push origin HEAD:"$KERNEL_BRANCH"
    ok "Pushed via default remote"
fi
