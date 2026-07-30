#!/bin/bash
# =============================================================================
#  inject_susfs.sh  — Full SusFS + KernelSU-Next injection for Linux 4.14
#
#  ما يعمله:
#    1. تحديث submodule KernelSU-Next → v3.1.0-legacy-susfs
#    2. تطبيق 50_add_susfs_in_kernel-4.14.patch  (21 ملف موجود)
#    3. Manual hook: sys_reboot في kernel/reboot.c
#    4. نسخ الملفات الجديدة: susfs.c, sus_su.c, susfs.h, susfs_def.h, sus_su.h
#    5. تطبيق KSU-side patch: 10_enable_susfs_for_ksu.patch
#    6. تحديث fs/Kconfig
#    7. تحديث ksu.config (كل الـ flags + Manual Hooks)
#    8. إضافة vbmeta للـ DTS (exynos9820 + 9825) لمنع bootloop
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
    # Required for v3.1.0-legacy-susfs Manual Hooks (KPROBES disabled).
    # Hook goes BEFORE capability/LINUX_REBOOT_MAGIC checks — KSU uses its own
    # KSU_INSTALL_MAGIC1 which would otherwise be rejected as -EINVAL.
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

    hook_block = (
      "\n#ifdef CONFIG_KSU\n"
      "\textern int ksu_handle_sys_reboot(int magic1, int magic2,"
      " unsigned int cmd, void __user **arg);\n"
      "\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n"
      "#endif\n"
    )

    # SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
    #                 void __user *, arg)
    # {                           <-- insert hook right after the opening brace
    pattern = re.compile(
      r'(SYSCALL_DEFINE4\s*\(\s*reboot\b[^)]*\)\s*\n\{)',
      re.MULTILINE
    )
    m = pattern.search(src)
    if m:
      insert_pos = m.end()
      new_src = src[:insert_pos] + hook_block + src[insert_pos:]
      open(path, 'w').write(new_src)
      print("OK: ksu_handle_sys_reboot inserted into kernel/reboot.c")
    else:
      print("ERROR: SYSCALL_DEFINE4(reboot) pattern not matched in " + path)
      sys.exit(1)
    PYEOF
      ok "sys_reboot hook injected into kernel/reboot.c"
    fi

    step "4/8 — Copy new kernel files (susfs.c, sus_su.c, susfs.h, susfs_def.h, sus_su.h)"
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
copy_file "sus_su.c" "$SUSFS_DIR/kernel_patches/fs/sus_su.c" "$KERNEL_DIR/fs/sus_su.c"

# ── include/linux/ new files ─────────────────────────────────────────────────
copy_file "susfs.h"     "$SUSFS_DIR/kernel_patches/include/linux/susfs.h"     "$KERNEL_DIR/include/linux/susfs.h"
copy_file "susfs_def.h" "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" "$KERNEL_DIR/include/linux/susfs_def.h"
copy_file "sus_su.h"    "$SUSFS_DIR/kernel_patches/include/linux/sus_su.h"    "$KERNEL_DIR/include/linux/sus_su.h"

# ─────────────────────────────────────────────────────────────────────────────
step "5/8 — Apply KSU-side patch (10_enable_susfs_for_ksu.patch)"
# ─────────────────────────────────────────────────────────────────────────────
KSU_PATCH=""
for c in \
    "$SUSFS_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" \
    "$SUSFS_DIR/kernel_patches/10_enable_susfs_for_ksu.patch"          \
    "$SUSFS_DIR/kernel_patches/KernelSU/0001-kernel-implement-susfs.patch"; do
    [ -f "$c" ] && KSU_PATCH="$c" && break
done

if [ -n "$KSU_PATCH" ]; then
    ok "Found KSU patch: $(basename "$KSU_PATCH")"
    KSU_KERN="$KERNEL_DIR/KernelSU-Next/kernel"
    if patch -p1 --dry-run --forward --fuzz=3 \
         --directory="$KSU_KERN" < "$KSU_PATCH" >/dev/null 2>&1; then
        patch -p1 --forward --fuzz=3 \
              --directory="$KSU_KERN" < "$KSU_PATCH"
        ok "KSU patch applied cleanly"
    else
        warn "KSU patch already applied or conflicts — skipping"
    fi
else
    warn "KSU-side patch not found — v3.1.0-legacy-susfs may already include it"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "6/8 — Wire SusFS into fs/Kconfig"
# ─────────────────────────────────────────────────────────────────────────────
FS_KCONFIG="$KERNEL_DIR/fs/Kconfig"

if grep -q 'KSU_SUSFS' "$FS_KCONFIG"; then
    ok "fs/Kconfig already has KSU_SUSFS"
else
    # Build the block in a temp file then insert before last endmenu
    BLOCK_FILE=$(mktemp)
    cat > "$BLOCK_FILE" << 'KCONFIG_BLOCK'

config KSU_SUSFS
	bool "Enable SusFS for KernelSU"
	depends on KSU
	default y if KSU
	help
	  Hides KernelSU traces from apps using SusFS filesystem hooks.

config KSU_SUSFS_SUS_PATH
	bool "Enable sus_path feature"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_MOUNT
	bool "Enable sus_mount feature"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_KSTAT
	bool "Enable sus_kstat feature"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_OVERLAYFS
	bool "Enable sus_overlayfs feature"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_TRY_UMOUNT
	bool "Enable try_umount feature"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SPOOFER
	bool "Enable spoofer feature"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_OPEN_REDIRECT
	bool "Enable open_redirect feature"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
	bool "Auto add sus_ksu default mount"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
	bool "Auto add try_umount for bind mount"
	depends on KSU_SUSFS
	default y
KCONFIG_BLOCK

    TMPKCONFIG=$(mktemp)
    awk -v block="$(cat "$BLOCK_FILE")" '
        /^endmenu/ && !done { print block; done=1 }
        { print }
    ' "$FS_KCONFIG" > "$TMPKCONFIG"
    mv "$TMPKCONFIG" "$FS_KCONFIG"
    rm -f "$BLOCK_FILE"
    ok "Added KSU_SUSFS config block to fs/Kconfig"
fi

# fs/Makefile — sus_su.o as well
FS_MK="$KERNEL_DIR/fs/Makefile"
if ! grep -q 'susfs.o' "$FS_MK"; then
    printf '\n# SusFS\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\nobj-$(CONFIG_KSU_SUSFS) += sus_su.o\n' >> "$FS_MK"
    ok "Added susfs.o + sus_su.o to fs/Makefile"
else
    ok "fs/Makefile already wired"
    # Add sus_su.o if missing
    if ! grep -q 'sus_su.o' "$FS_MK"; then
        sed -i '/susfs.o/a obj-$(CONFIG_KSU_SUSFS) += sus_su.o' "$FS_MK"
        ok "Added sus_su.o to fs/Makefile"
    fi
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
# Manual Hooks — disable KPROBES (prevents bootloop on 4.14)
disable_opt KSU_KPROBES_HOOK
disable_opt KPROBES

ok "ksu.config updated"

# ─────────────────────────────────────────────────────────────────────────────
step "8/8 — vbmeta DTS fix (exynos9820 + exynos9825) — prevents bootloop"
# ─────────────────────────────────────────────────────────────────────────────
# Adds vbmeta node with status=disabled inside android {} firmware block.
# Required on Samsung Exynos devices to avoid AVB verification bootloop.

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
    mv "$TMPF" "$dts_file"
    ok "  $(basename "$dts_file") — vbmeta block added"
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
  fs/susfs.c fs/sus_su.c
  include/linux/susfs.h include/linux/susfs_def.h include/linux/sus_su.h

KernelSU-Next:
  Submodule updated to ${KSU_TAG} (legacy-susfs, Manual Hooks)
  10_enable_susfs_for_ksu.patch applied

Config:
  ksu.config: CONFIG_KSU_SUSFS=y + all feature flags
  ksu.config: KPROBES disabled (Manual Hooks — no bootloop)

DTS (bootloop fix):
  arch/arm64/boot/dts/exynos/exynos9820.dts: vbmeta node added
  arch/arm64/boot/dts/exynos/exynos9825.dts: vbmeta node added
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
