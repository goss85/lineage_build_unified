#!/bin/bash
echo ""
echo "LineageOS 17.x Treble Buildbot for Lenovo TB-X104L"
echo "ATTENTION: this script syncs repo on each run"
echo "Executing in 5 seconds - CTRL-C to exit"
echo ""
sleep 5

# Abort early on error
set -eE
trap '(\
echo;\
echo \!\!\! An error happened during script execution;\
echo \!\!\! Please check console output for bad sync,;\
echo \!\!\! failed patch application, etc.;\
echo\
)' ERR

START=`date +%s`
BUILD_DATE="$(date +%Y%m%d)"
BL=$PWD/treble_build_los
TREBLE_PATCHES_BRANCH="${TREBLE_PATCHES_BRANCH:-lineage-17.1-TB-X104L}"
TREBLE_PATCHES_REV="${TREBLE_PATCHES_REV:-}"
ENABLE_PINNED_PATCHED_PROJECTS="${ENABLE_PINNED_PATCHED_PROJECTS:-0}"
SYNC_JOBS="${SYNC_JOBS:-4}"
BUILD_JOBS="${BUILD_JOBS:-4}"
USE_CCACHE="${USE_CCACHE:-1}"
CCACHE_DIR="${CCACHE_DIR:-/ccache}"
CCACHE_MAX_SIZE="${CCACHE_MAX_SIZE:-50G}"
CCACHE_EXEC="${CCACHE_EXEC:-$(command -v ccache || true)}"
BOOTANIMATION_ROTATION="${BOOTANIMATION_ROTATION:-90}"
ROTATE_BOOTANIMATION="${ROTATE_BOOTANIMATION:-1}"
PINNED_CUTOFF_UTC="${PINNED_CUTOFF_UTC:-2021-08-08 23:59:59 +0000}"

setup_ccache() {
    if [ "$USE_CCACHE" = "0" ]; then
        echo "ccache disabled (USE_CCACHE=0)"
        return
    fi
    if [ -z "$CCACHE_EXEC" ] || [ ! -x "$CCACHE_EXEC" ]; then
        echo "WARN: ccache binary not found; continuing without ccache"
        return
    fi

    export USE_CCACHE=1
    export CCACHE_DIR
    export CCACHE_EXEC
    mkdir -p "$CCACHE_DIR"

    "$CCACHE_EXEC" -M "$CCACHE_MAX_SIZE" >/dev/null || true
    "$CCACHE_EXEC" -o compression=true >/dev/null || true

    echo "ccache enabled: exec=$CCACHE_EXEC dir=$CCACHE_DIR max=$CCACHE_MAX_SIZE"
    "$CCACHE_EXEC" -s || true
}

setup_ccache

ensure_webview_prebuilts() {
    local base="external/chromium-webview/prebuilt"
    local need_lfs=0
    local arch=""

    for arch in arm arm64 x86 x86_64; do
        local apk="$base/$arch/webview.apk"
        [ -f "$apk" ] || continue
        if head -n 1 "$apk" | grep -q "git-lfs.github.com/spec/v1"; then
            need_lfs=1
            break
        fi
    done

    [ "$need_lfs" -eq 0 ] && return 0

    echo "Detected Git LFS pointer files in chromium-webview prebuilts."
    if ! command -v git-lfs >/dev/null 2>&1; then
        echo "ERROR: git-lfs is not installed, cannot download webview APK prebuilts."
        echo "Install git-lfs in your Docker image (e.g. apt-get update && apt-get install -y git-lfs), then rerun."
        exit 1
    fi

    for arch in arm arm64 x86 x86_64; do
        local repo="$base/$arch"
        local apk="$repo/webview.apk"

        [ -d "$repo/.git" ] || continue
        [ -f "$apk" ] || continue
        if ! head -n 1 "$apk" | grep -q "git-lfs.github.com/spec/v1"; then
            continue
        fi

        echo "Fetching LFS object for $apk"
        git -C "$repo" lfs install --local
        git -C "$repo" lfs pull --include="webview.apk"
    done

    for arch in arm arm64 x86 x86_64; do
        local apk="$base/$arch/webview.apk"
        [ -f "$apk" ] || continue
        if head -n 1 "$apk" | grep -q "git-lfs.github.com/spec/v1"; then
            echo "ERROR: $apk is still an LFS pointer after git lfs pull."
            exit 1
        fi
    done
}

pin_project_by_cutoff() {
    local project="$1"
    local cutoff="$2"
    local ref=""
    local commit=""

    [ -d "$project/.git" ] || return 0

    for pattern in refs/remotes/*/lineage-17.1 refs/remotes/*/lineage-17.0 refs/remotes/*/lineage-16.0 refs/remotes/*/master; do
        ref="$(git -C "$project" for-each-ref --format='%(refname:short)' "$pattern" | head -n 1)"
        [ -n "$ref" ] && break
    done

    [ -z "$ref" ] && return 0

    # Avoid hard failure when a previous interrupted run left local changes.
    if [ -n "$(git -C "$project" status --porcelain=v1 2>/dev/null)" ]; then
        echo "WARN: $project has local changes; skipping pin checkout"
        return 0
    fi

    commit="$(git -C "$project" rev-list -n 1 --before="$cutoff" "$ref" || true)"
    [ -n "$commit" ] && git -C "$project" checkout -q "$commit"
}

pin_patched_projects() {
    local cutoff="$1"
    local patch_root="$2"

    echo "Pinning patched projects to commits before: $cutoff"

    for project in $(cd "$patch_root/patches" && echo *); do
        local p
        p="$(tr _ / <<<"$project" | sed -e 's;platform/;;g')"
        [ "$p" == build ] && p=build/make
        pin_project_by_cutoff "$p" "$cutoff"
    done

    for p in vendor/lineage hardware/lineage/interfaces lineage-sdk packages/apps/LineageParts system/hardware/interfaces system/sepolicy; do
        pin_project_by_cutoff "$p" "$cutoff"
    done
}

echo "Preparing local manifest"
mkdir -p .repo/local_manifests
cp $BL/manifest.xml .repo/local_manifests/manifest.xml
echo ""

echo "Syncing repos"
MANIFEST_REV="${LOS_MANIFEST_REV:-default}"
git -C .repo/manifests checkout "$MANIFEST_REV"
for d in external/chromium-webview/{patches,prebuilt/arm,prebuilt/arm64,prebuilt/x86,prebuilt/x86_64}; do
    if [ -d "$d/.git" ]; then
        git -C "$d" reset --hard || true
        git -C "$d" clean -fdx || true
    fi
done
repo sync -c --no-manifest-update --force-sync --no-clone-bundle --no-tags -j"${SYNC_JOBS}"
ensure_webview_prebuilts
git -C treble_patches fetch --prune origin "$TREBLE_PATCHES_BRANCH"
if [ -n "$TREBLE_PATCHES_REV" ]; then
    if ! git -C treble_patches rev-parse -q --verify "${TREBLE_PATCHES_REV}^{commit}" >/dev/null; then
        echo "ERROR: treble_patches commit not found: $TREBLE_PATCHES_REV"
        exit 1
    fi
    git -C treble_patches checkout "$TREBLE_PATCHES_REV"
else
    git -C treble_patches checkout -B "$TREBLE_PATCHES_BRANCH" "origin/$TREBLE_PATCHES_BRANCH"
fi
if [ "$ENABLE_PINNED_PATCHED_PROJECTS" = "1" ]; then
    pin_patched_projects "$PINNED_CUTOFF_UTC" "$PWD/treble_patches"
else
    echo "Skipping patched-project pinning (ENABLE_PINNED_PATCHED_PROJECTS=$ENABLE_PINNED_PATCHED_PROJECTS)"
fi
echo ""

echo "Setting up build environment"
source build/envsetup.sh &> /dev/null
echo ""

echo "Reverting LOS FOD implementation"
cd frameworks/base
git am $BL/patches/0001-Squashed-revert-of-LOS-FOD-implementation.patch
cd ../..
cd vendor/lineage
git revert 612c5a846ea5aed339fe1275c119ee111faae78c --no-edit # soong: Add flag for fod extension
cd ../..
echo ""

echo "Applying PHH patches"
rm -f device/*/sepolicy/common/private/genfs_contexts
cd device/phh/treble
git clean -fdx
bash generate.sh lineage
cd ../../..
if [ -f "$HOME/treble_experimentations/apply-patches.sh" ]; then
    APPLY_PATCHES_SH="$HOME/treble_experimentations/apply-patches.sh"
elif [ -f "/home/builder/treble_experimentations/apply-patches.sh" ]; then
    APPLY_PATCHES_SH="/home/builder/treble_experimentations/apply-patches.sh"
else
    echo "ERROR: apply-patches.sh not found under \$HOME/treble_experimentations or /home/builder/treble_experimentations"
    exit 1
fi
PHH_NO_SYNC_RESET=1 bash "$APPLY_PATCHES_SH" treble_patches
# Android 10 system/bt exposes bthh_interface_t::disconnect with one argument.
# Keep the JNI side matched after repo sync resets packages/apps/Bluetooth.
sed -i 's#sBluetoothHidInterface->disconnect((RawAddress*)addr, reconnect_allowed)#sBluetoothHidInterface->disconnect((RawAddress*)addr)#' packages/apps/Bluetooth/jni/com_android_bluetooth_hid_host.cpp
if git -C device/phh/treble apply --check "$BL/patches/0001-device_phh_treble-Force-BTM_BYPASS_EXTRA_ACL_SETUP.patch" >/dev/null 2>&1; then
    git -C device/phh/treble apply "$BL/patches/0001-device_phh_treble-Force-BTM_BYPASS_EXTRA_ACL_SETUP.patch"
elif git -C device/phh/treble apply --reverse --check "$BL/patches/0001-device_phh_treble-Force-BTM_BYPASS_EXTRA_ACL_SETUP.patch" >/dev/null 2>&1; then
    echo "Patch already applied: 0001-device_phh_treble-Force-BTM_BYPASS_EXTRA_ACL_SETUP.patch"
else
    echo "ERROR: Cannot apply patch: $BL/patches/0001-device_phh_treble-Force-BTM_BYPASS_EXTRA_ACL_SETUP.patch"
    exit 1
fi
if git -C device/phh/treble apply --check "$BL/patches/0001-device_phh_treble-Include-TB-X104L-system-prop.patch" >/dev/null 2>&1; then
    git -C device/phh/treble apply "$BL/patches/0001-device_phh_treble-Include-TB-X104L-system-prop.patch"
elif git -C device/phh/treble apply --reverse --check "$BL/patches/0001-device_phh_treble-Include-TB-X104L-system-prop.patch" >/dev/null 2>&1; then
    echo "Patch already applied: 0001-device_phh_treble-Include-TB-X104L-system-prop.patch"
else
    echo "ERROR: Cannot apply patch: $BL/patches/0001-device_phh_treble-Include-TB-X104L-system-prop.patch"
    exit 1
fi
cd frameworks/native
git am $BL/patches/0001-Revert-surfaceflinger-Add-support-for-extension-lib.patch
cd ../..
echo ""

echo "Applying universal patches"
cd frameworks/base
git am $BL/patches/0001-UI-Revive-navbar-layout-tuning-via-sysui_nav_bar-tun.patch
git am $BL/patches/0001-Disable-vendor-mismatch-warning.patch
git am $BL/patches/0001-MicroG-LOS17_1.patch
#git apply $BL/patches/0001-frameworks_base-BootAnimation-rotate-surface-to-match-display.patch
#git apply $BL/patches/0001-frameworks_base-VolumeDialog-force-full-redraw-on-first-show.patch
git apply $BL/patches/0001-frameworks_base-Keyguard-keep-current-rotation-when.patch
#git apply $BL/patches/0001-frameworks_base-Default-mRotation-ROTATION_90.patch
cd ../..
cd lineage-sdk
git am $BL/patches/0001-sdk-Invert-per-app-stretch-to-fullscreen.patch
cd ..
cd packages/apps/LineageParts
git am $BL/patches/0001-LineageParts-Invert-per-app-stretch-to-fullscreen.patch
cd ../../..
cd vendor/lineage
git am $BL/patches/0001-vendor_lineage-Log-privapp-permissions-whitelist-vio.patch
cd ../..
cd vendor/vndk-tests
if git apply --check "$BL/patches/0001-vndk-tests-Skip-missing-selinux-mapping-versions.patch" >/dev/null 2>&1; then
    git apply "$BL/patches/0001-vndk-tests-Skip-missing-selinux-mapping-versions.patch"
elif git apply --reverse --check "$BL/patches/0001-vndk-tests-Skip-missing-selinux-mapping-versions.patch" >/dev/null 2>&1; then
    echo "Patch already applied: 0001-vndk-tests-Skip-missing-selinux-mapping-versions.patch"
else
    echo "ERROR: Cannot apply patch: $BL/patches/0001-vndk-tests-Skip-missing-selinux-mapping-versions.patch"
    exit 1
fi
cd ../..
echo ""

echo "Applying GSI-specific patches"
cd build/make
git am $BL/patches/0001-build-Don-t-handle-apns-conf.patch
cd ../..
cd device/phh/treble
git revert 82b15278bad816632dcaeaed623b569978e9840d --no-edit # Update lineage.mk for LineageOS 16.0
git am $BL/patches/0001-Remove-fsck-SELinux-labels.patch
git am $BL/patches/0001-treble-Add-overlay-lineage.patch
git am $BL/patches/0001-treble-Don-t-specify-config_wallpaperCropperPackage.patch
git am $BL/patches/0001-treble-Don-t-handle-apns-conf.patch
git am $BL/patches/0001-TEMP-treble-Fix-init.treble-environ.rc-hardcode-for-.patch
cd ../../..
cd hardware/lineage/interfaces
git am $BL/patches/0001-cryptfshw-Remove-dependency-on-generated-kernel-head.patch
cd ../../..
cd system/hardware/interfaces
git revert 5c145c49cc83bfe37c740bcfd3f82715ee051122 --no-edit # system_suspend: start early
cd ../../..
cd system/sepolicy
git revert d12551bf1a6e8a9ece6bbb98344a27bde7f9b3e1 --no-edit # sepolicy: Relabel wifi. properties as wifi_prop
git am $BL/patches/0001-Revert-sepolicy-Address-denials-for-legacy-last_kmsg.patch
cd ../..
cd vendor/lineage
git am $BL/patches/0001-build_soong-Disable-generated_kernel_headers.patch
cd ../..
echo ""

echo "CHECK PATCH STATUS NOW!"
sleep 5
echo ""

export WITHOUT_CHECK_API=true
export WITH_SU=true
mkdir -p ~/build-output/

rotate_bootanimation_in_out() {
    if [ "$ROTATE_BOOTANIMATION" != "1" ]; then
        echo "Bootanimation rotation disabled (ROTATE_BOOTANIMATION=$ROTATE_BOOTANIMATION)"
        return 0
    fi

    local rotate_script="$BL/rotate_bootanimation.sh"
    local target_zip="$OUT/system/media/bootanimation.zip"
    local rotated_zip="$OUT/system/media/bootanimation-rotated.zip"

    if [ ! -f "$rotate_script" ]; then
        echo "ERROR: rotate script not found: $rotate_script"
        return 1
    fi
    if [ ! -f "$target_zip" ]; then
        echo "ERROR: bootanimation not found: $target_zip"
        return 1
    fi

    echo "Rotating bootanimation to landscape (${BOOTANIMATION_ROTATION} deg)"
    bash "$rotate_script" "$target_zip" "$rotated_zip" "$BOOTANIMATION_ROTATION"
    mv -f "$rotated_zip" "$target_zip"

}

buildVariant() {
	lunch ${1}-userdebug
	make installclean
	rm -rf "$OUT/obj/ETC/bootanimation.zip_intermediates" "$OUT/obj/BOOTANIMATION"
	make -j"${BUILD_JOBS}" systemimage
	rotate_bootanimation_in_out
	# Repack system image from updated out/target/.../system tree.
    make -j"${BUILD_JOBS}" snod
	make vndk-test-sepolicy
	mv $OUT/system.img ~/build-output/lineage-17.1-$BUILD_DATE-UNOFFICIAL-${1}.img
}

ls ~/build-output | grep 'lineage' || true

END=`date +%s`
ELAPSEDM=$(($(($END-$START))/60))
ELAPSEDS=$(($(($END-$START))-$ELAPSEDM*60))
echo "Buildbot completed in $ELAPSEDM minutes and $ELAPSEDS seconds"
echo ""
buildVariant treble_arm_avS
ls ~/build-output | grep 'lineage' || true
if [ -n "${CCACHE_EXEC:-}" ] && [ -x "$CCACHE_EXEC" ]; then
    echo ""
    echo "ccache stats:"
    "$CCACHE_EXEC" -s || true
fi
