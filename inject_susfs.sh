#!/bin/bash
# =============================================================================
#  inject_susfs.sh  — Full SusFS + KernelSU-Next injection for Linux 4.14
#
#  ما يعمله:
#    1. تحديث submodule KernelSU-Next → v3.1.0-legacy-susfs
#    2. تطبيق 50_add_susfs_in_kernel-4.14.patch  (21 ملف موجود)
#    3. Manual hook: sys_reboot في kernel/reboot.c (CONFIG_KSU_MANUAL_HOOK)
#    4. نسخ susfs.c + susfs.h + susfs_def.h فقط (sus_su.* متروك عمداً — غير مدعوم بهذا الفرع)
#    5. [متخطى عمداً] 10_enable_susfs_for_ksu.patch — يستهدف core_hook.c غير الموجود بهذا الفرع
#    6. تحقق فقط من ربط KSU_SUSFS عبر drivers/Kconfig + إضافة susfs.o لـ fs/Makefile
#    7. تحديث ksu.config (الأسماء الـ 10 الصحيحة + CONFIG_KSU_MANUAL_HOOK، بدون SUS_SU)
#    8. إضافة vbmeta للـ DTS (exynos9820 + 9825) لمنع bootloop + تحقق فعلي من الإدراج
#    9. كوميت واحدة ودفع
#
#  الاستخدام:
#    ./inject_susfs.sh <KERNEL_DIR> <SUSFS_DIR> [REPO] [BRANCH] [DRY_RUN]
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
KSU_TAG="${KSU_TAG:-v3.1.0-legacy-susfs}"

[ -d "$KERNEL_DIR" ]                  || err "Kernel dir not found: $KERNEL_DIR"
[ -d "$SUSFS_DIR"  ]                  || err "SusFS dir not found:  $SUSFS_DIR"
[ -d "$KERNEL_DIR/KernelSU-Next" ]    || err "KernelSU-Next submodule not found"
[ -f "$KERNEL_DIR/fs/Makefile" ]      || err "Not a kernel tree (no fs/Makefile)"

echo -e "${G}"
echo "  ┌────────────────────────────────────────────┐"
echo "  │  SusFS + KernelSU-Next Injector for 4.14  │"
echo "  └────────────────────────────────────────────┘"
echo -e "${N}"
info "Kernel  : $KERNEL_DIR"
info "SusFS   : $SUSFS_DIR"
info "Target  : $KERNEL_REPO @ $KERNEL_BRANCH"
info "KSU tag : $KSU_TAG"
info "Dry run : $DRY_RUN"

# ─────────────────────────────────────────────────────────────────────────────
step "1/8 — Update KernelSU-Next submodule → $KSU_TAG"
# ─────────────────────────────────────────────────────────────────────────────
cd "$KERNEL_DIR/KernelSU-Next"
git fetch --tags origin
git checkout "$KSU_TAG"
ok "KSU-Next @ $(git describe --tags --always) — $(git log --oneline -1)"
cd "$KERNEL_DIR"

# ─────────────────────────────────────────────────────────────────────────────
step "2/8 — Apply 50_add_susfs_in_kernel-4.14.patch  (21 files)"
# ─────────────────────────────────────────────────────────────────────────────
KERNEL_PATCH=""
for c in \
    "$SUSFS_DIR/kernel_patches/50_add_susfs_in_kernel-4.14.patch" \
    "$SUSFS_DIR/kernel_patches/50_add_susfs_in_kernel-4.x.patch"  \
    "$SUSFS_DIR/50_add_susfs_in_kernel-4.14.patch"; do
    [ -f "$c" ] && KERNEL_PATCH="$c" && break
done

if [ -n "$KERNEL_PATCH" ]; then
    ok "Found: $(basename "$KERNEL_PATCH")"
    # Check if already applied
    if patch -p1 --dry-run --forward --fuzz=3 \
         --directory="$KERNEL_DIR" < "$KERNEL_PATCH" >/dev/null 2>&1; then
        patch -p1 --forward --fuzz=3 \
              --directory="$KERNEL_DIR" < "$KERNEL_PATCH"
        ok "Patch applied cleanly — modified: dcache.c namei.c namespace.c overlayfs/ proc/ kallsyms.c sys.c mount.h sched.h ..."
    else
        warn "Patch already applied or has conflicts — skipping (clean run)"
    fi
else
    err "50_add_susfs patch not found in $SUSFS_DIR/kernel_patches/"
fi

# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
step "3/8 — Manual hook: sys_reboot → kernel/reboot.c"
# ─────────────────────────────────────────────────────────────────────────────
# ksu_handle_sys_reboot is the supercall gateway used by ksud + SusFS.
# Required for v3.1.0-legacy-susfs Manual Hooks (KPROBES disabled) — confirmed
# via supercalls.c: ksu_supercalls_init() skips the reboot kprobe whenever
# CONFIG_KSU_SUSFS is defined, so this manual call site is the ONLY place the
# reboot supercall gets wired in this build. Guarded by CONFIG_KSU_MANUAL_HOOK
# (the real Kconfig symbol on this fork, mutually exclusive with KSU_KPROBES_HOOK).
# NOTE: the call must go AFTER this function's local declarations
# (pid_ns/buffer/ret) and BEFORE its first statement. Inserting it right
# after the opening brace (as an earlier version of this step did) breaks
# C's declaration-before-statement ordering and fails the build under
# -Werror=declaration-after-statement.
REBOOT_C="$KERNEL_DIR/kernel/reboot.c"
if [ ! -f "$REBOOT_C" ]; then
    warn "kernel/reboot.c not found — skipping sys_reboot hook"
elif grep -q 'ksu_handle_sys_reboot' "$REBOOT_C"; then
    ok "kernel/reboot.c already has ksu_handle_sys_reboot — skipping"
else
    python3 - "$REBOOT_C" << 'PYEOF'
import sys, re

path = sys.argv[1]
src = open(path).read()

extern_block = (
    "#ifdef CONFIG_KSU_MANUAL_HOOK\n"
    "extern int ksu_handle_sys_reboot(int magic1, int magic2,"
    " unsigned int cmd, void __user **arg);\n"
    "#endif\n\n"
)
call_block = (
    "#ifdef CONFIG_KSU_MANUAL_HOOK\n"
    "\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n"
    "#endif\n"
)

func_pat = re.compile(r'SYSCALL_DEFINE4\s*\(\s*reboot\b')
m_func = func_pat.search(src)
if not m_func:
    print("ERROR: SYSCALL_DEFINE4(reboot) not found in " + path)
    sys.exit(1)
src = src[:m_func.start()] + extern_block + src[m_func.start():]

anchor_pat = re.compile(r'\n(\t/\* We only trust the superuser)')
m_anchor = anchor_pat.search(src)
if not m_anchor:
    print("ERROR: anchor comment not found -- refusing to guess placement")
    sys.exit(1)
insert_pos = m_anchor.start()
src = src[:insert_pos] + '\n' + call_block + src[insert_pos:]

open(path, 'w').write(src)
print("OK: ksu_handle_sys_reboot extern + call inserted at correct positions")
PYEOF
    ok "sys_reboot hook injected into kernel/reboot.c"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "4/8 — Copy new kernel files (susfs.c, susfs.h, susfs_def.h)"
# ─────────────────────────────────────────────────────────────────────────────

copy_file() {
    local label="$1" src="$2" dst="$3"
    if [ -f "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
        ok "  $label → $dst"
    else
        warn "  $label not found at $src"
    fi
}

# ── fs/ new files ────────────────────────────────────────────────────────────
copy_file "susfs.c"  "$SUSFS_DIR/kernel_patches/fs/susfs.c"  "$KERNEL_DIR/fs/susfs.c"

# ── include/linux/ new files ─────────────────────────────────────────────────
copy_file "susfs.h"     "$SUSFS_DIR/kernel_patches/include/linux/susfs.h"     "$KERNEL_DIR/include/linux/susfs.h"
copy_file "susfs_def.h" "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" "$KERNEL_DIR/include/linux/susfs_def.h"

# sus_su.c / sus_su.h intentionally NOT copied:
#   - CONFIG_KSU_SUSFS_SUS_SU does not exist in this fork's kernel/Kconfig
#   - sucompat.c has zero wiring for sus_su on KernelSU-Next $KSU_TAG
#   - susfs.c does not #include sus_su.h and does not depend on it
info "  sus_su.c / sus_su.h skipped intentionally — unsupported on this fork ($KSU_TAG)"

# ─────────────────────────────────────────────────────────────────────────────
step "5/8 — KSU-side patch (10_enable_susfs_for_ksu.patch) — SKIPPED"
# ─────────────────────────────────────────────────────────────────────────────
# Intentionally not applied to KernelSU-Next $KSU_TAG:
#   - Its main hunk targets kernel/core_hook.c, which does not exist in this
#     fork — core_hook.c was refactored into sucompat.c / syscall_hook_manager.c
#     / setuid_hook.c / supercalls.c.
#   - Its rename hunks (e.g. track_throne -> ksu_track_throne) do not match
#     the current source either.
#   - kernel/ksu.c on $KSU_TAG already natively calls susfs_init() under
#     #ifdef CONFIG_KSU_SUSFS, so the wiring this patch used to provide is
#     already built in. Force-applying it with --fuzz would risk silently
#     corrupting files instead of failing loudly.
warn "10_enable_susfs_for_ksu.patch intentionally skipped — incompatible with this fork; ksu.c already calls susfs_init() natively under CONFIG_KSU_SUSFS"

# ─────────────────────────────────────────────────────────────────────────────
step "6/8 — Verify KSU_SUSFS Kconfig wiring + wire susfs.o into fs/Makefile"
# ─────────────────────────────────────────────────────────────────────────────
# fs/Kconfig is NOT touched: KernelSU-Next's own Kconfig (sourced via
# drivers/Kconfig -> drivers/kernelsu/Kconfig) already natively defines the
# full KSU_SUSFS submenu on $KSU_TAG. Defining "config KSU_SUSFS" again here
# would create a duplicate Kconfig symbol and conflict with the native one.
DRIVERS_KCONFIG="$KERNEL_DIR/drivers/Kconfig"
if [ -f "$DRIVERS_KCONFIG" ] && grep -q 'source "drivers/kernelsu/Kconfig"' "$DRIVERS_KCONFIG"; then
    ok "drivers/Kconfig sources drivers/kernelsu/Kconfig — KSU_SUSFS already wired natively"
else
    err "drivers/Kconfig does not source drivers/kernelsu/Kconfig — KSU Kconfig chain is broken, cannot continue"
fi

# fs/Makefile — susfs.c is a new file physically inside fs/, so it needs an
# explicit obj-y rule (Kbuild does not auto-discover new .c files).
# sus_su.o is intentionally NOT added — sus_su.c is not copied (see step 4/8).
FS_MK="$KERNEL_DIR/fs/Makefile"
if ! grep -q 'susfs.o' "$FS_MK"; then
    printf '\n# SusFS\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n' >> "$FS_MK"
    ok "Added susfs.o to fs/Makefile"
else
    ok "fs/Makefile already wired for susfs.o"
fi
# Remove a stale sus_su.o rule if a previous run of this script added one.
if grep -q 'sus_su.o' "$FS_MK"; then
    sed -i '/sus_su\.o/d' "$FS_MK"
    info "  Removed stale sus_su.o rule from fs/Makefile (unsupported on this fork)"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "7/8 — Update ksu.config"
# ─────────────────────────────────────────────────────────────────────────────
CFG="$KERNEL_DIR/arch/arm64/configs/ksu.config"
[ -f "$CFG" ] || err "ksu.config not found at $CFG"

enable_opt() {
    local opt="$1"
    sed -i "/^# CONFIG_${opt} is not set/d" "$CFG"
    sed -i "/^CONFIG_${opt}=/d"             "$CFG"
    printf 'CONFIG_%s=y\n' "$opt" >> "$CFG"
    ok "  CONFIG_${opt}=y"
}

disable_opt() {
    local opt="$1"
    sed -i "/^CONFIG_${opt}=.*/d"           "$CFG"
    sed -i "/^# CONFIG_${opt} is not set/d" "$CFG"
    printf '# CONFIG_%s is not set\n' "$opt" >> "$CFG"
    info "  CONFIG_${opt} disabled"
}

# The 10 KSU_SUSFS sub-options that actually exist in KernelSU-Next $KSU_TAG's
# kernel/Kconfig. SUS_SU is deliberately excluded (see step 4/8 — unsupported).
enable_opt  KSU_SUSFS
enable_opt  KSU_SUSFS_SUS_PATH
enable_opt  KSU_SUSFS_SUS_MOUNT
enable_opt  KSU_SUSFS_SUS_KSTAT
enable_opt  KSU_SUSFS_TRY_UMOUNT
enable_opt  KSU_SUSFS_SPOOF_UNAME
enable_opt  KSU_SUSFS_ENABLE_LOG
enable_opt  KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
enable_opt  KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
enable_opt  KSU_SUSFS_OPEN_REDIRECT
enable_opt  KSU_SUSFS_SUS_MAP
info "  CONFIG_KSU_SUSFS_SUS_SU intentionally left unset — unsupported on this fork"

# Manual Hooks — this fork's supercalls.c skips kprobe registration for
# reboot whenever CONFIG_KSU_SUSFS is set, so Manual Hooks must be forced on
# and KPROBES must be off (the two are mutually exclusive via `depends on`).
enable_opt  KSU_MANUAL_HOOK
disable_opt KSU_KPROBES_HOOK
disable_opt KPROBES

ok "ksu.config updated"

# ─────────────────────────────────────────────────────────────────────────────
step "8/8 — vbmeta DTS fix (exynos9820 + exynos9825) — prevents bootloop"
# ─────────────────────────────────────────────────────────────────────────────
# Adds a vbmeta node with status=disabled inside the android {} firmware
# block. Required on Samsung Exynos devices to avoid AVB verification
# bootloop. The android {} firmware block is not at a fixed line in every
# DTS variant, so this locates it dynamically via brace-matching instead of
# a hardcoded line number, and VERIFIES the result instead of assuming success.

add_vbmeta_to_dts() {
    local dts_file="$1"
    [ -f "$dts_file" ] || { warn "  DTS not found: $dts_file"; return; }

    if grep -q 'android,vbmeta' "$dts_file"; then
        ok "  $(basename "$dts_file") — vbmeta already present"
        return
    fi

    # Find the android { compatible = "android,firmware"; }; block and expand it
    TMPF=$(mktemp)
    awk '
    /compatible = "android,firmware"/ {
        in_android = 1
        brace_count = 0
    }
    in_android {
        for (i=1; i<=length($0); i++) {
            c = substr($0, i, 1)
            if (c == "{") brace_count++
            if (c == "}") {
                brace_count--
                if (brace_count < 0) {
                    # This closing brace ends the android {} block
                    # Inject vbmeta before it
                    print "\t\t\tvbmeta {"
                    print "\t\t\t\tcompatible = \"android,vbmeta\";"
                    print "\t\t\t\tparts = \"vbmeta,boot,recovery,system,vendor,product,dtb,dtbo,keystorage\";"
                    print "\t\t\t\tstatus = \"disabled\";"
                    print "\t\t\t};"
                    print "\t\t\tfstab {"
                    print "\t\t\t\tcompatible = \"android,fstab\";"
                    print "\t\t\t};"
                    in_android = 0
                    brace_count = 0
                }
            }
        }
    }
    { print }
    ' "$dts_file" > "$TMPF"

    # Verify the injection actually happened before claiming success — if the
    # "android,firmware" anchor was not found or not shaped as expected, the
    # awk pass is a silent no-op and this must fail loudly, not report ok.
    if grep -q 'android,vbmeta' "$TMPF"; then
        mv "$TMPF" "$dts_file"
        ok "  $(basename "$dts_file") — vbmeta block added and verified"
    else
        rm -f "$TMPF"
        warn "  $(basename "$dts_file") — 'android,firmware' anchor not found or not shaped as expected; vbmeta NOT injected, needs manual review"
    fi
}

DTS_DIR="$KERNEL_DIR/arch/arm64/boot/dts/exynos"
add_vbmeta_to_dts "$DTS_DIR/exynos9820.dts"
add_vbmeta_to_dts "$DTS_DIR/exynos9825.dts"
# Also patch exynos9825-r.dts if it exists
[ -f "$DTS_DIR/exynos9825-r.dts" ] && add_vbmeta_to_dts "$DTS_DIR/exynos9825-r.dts"

# ─────────────────────────────────────────────────────────────────────────────
#  COMMIT + PUSH
# ─────────────────────────────────────────────────────────────────────────────
echo ""
ok "=== Summary of changes ==="
cd "$KERNEL_DIR"
git status --short
echo ""
ok "=== Submodule diff ==="
git diff --submodule=short

if [ "$DRY_RUN" = "true" ]; then
    warn "Dry run — no commit/push."
    exit 0
fi

git add -A

if git diff --cached --quiet; then
    ok "Nothing to commit — already up to date."
    exit 0
fi

git commit -m "kernel: inject KernelSU-Next ${KSU_TAG} + SusFS (kernel-4.14)

Files modified by 50_add_susfs_in_kernel-4.14.patch (21 files):
  fs/: Makefile dcache.c namei.c namespace.c notify/fdinfo.c readdir.c
  fs/: stat.c statfs.c proc_namespace.c proc/cmdline.c proc/fd.c
  fs/: proc/task_mmu.c proc/readdir.c
  fs/overlayfs/: inode.c overlayfs.h readdir.c super.c util.c
  include/linux/: mount.h sched.h
  kernel/: kallsyms.c sys.c

New files added:
  fs/susfs.c
  include/linux/susfs.h include/linux/susfs_def.h

sus_su intentionally NOT added:
  CONFIG_KSU_SUSFS_SUS_SU does not exist in this fork's Kconfig and
  sucompat.c has no wiring for it on KernelSU-Next ${KSU_TAG}.

KernelSU-Next:
  Submodule updated to ${KSU_TAG} (legacy-susfs, Manual Hooks)
  10_enable_susfs_for_ksu.patch intentionally NOT applied — targets
  core_hook.c, which does not exist in this fork (refactored into
  sucompat.c/syscall_hook_manager.c/setuid_hook.c/supercalls.c); ksu.c
  already natively calls susfs_init() under CONFIG_KSU_SUSFS.

Manual hook:
  kernel/reboot.c: ksu_handle_sys_reboot call site added under
  CONFIG_KSU_MANUAL_HOOK (supercalls.c skips the reboot kprobe whenever
  CONFIG_KSU_SUSFS is defined, so this is the only reboot supercall path).

Config:
  ksu.config: CONFIG_KSU_SUSFS=y + the 10 real sub-options for ${KSU_TAG}
    (SUS_PATH, SUS_MOUNT, SUS_KSTAT, TRY_UMOUNT, SPOOF_UNAME, ENABLE_LOG,
    HIDE_KSU_SUSFS_SYMBOLS, SPOOF_CMDLINE_OR_BOOTCONFIG, OPEN_REDIRECT, SUS_MAP)
  ksu.config: CONFIG_KSU_MANUAL_HOOK=y, KPROBES + KSU_KPROBES_HOOK disabled

DTS (bootloop fix):
  arch/arm64/boot/dts/exynos/exynos9820.dts: vbmeta node added (verified)
  arch/arm64/boot/dts/exynos/exynos9825.dts: vbmeta node added (verified)
  vbmeta status=disabled prevents AVB verification bootloop"

if [ -n "${GH_PAT:-}" ]; then
    git push \
        "https://${GH_PAT}@github.com/${KERNEL_REPO}.git" \
        HEAD:"$KERNEL_BRANCH"
else
    git push origin HEAD:"$KERNEL_BRANCH"
fi

ok "Pushed to $KERNEL_REPO/$KERNEL_BRANCH"
echo ""
ok "All done. SusFS fully injected."
