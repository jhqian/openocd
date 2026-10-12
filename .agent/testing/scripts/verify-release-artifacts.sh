#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Verify release artifacts produced by .github/workflows/release.yml.
#
# Test case mapping (see release verification plan):
#   T-B1  sha256 integrity of all archives
#   T-B2  Linux dynamic deps allowlist (ldd on pd-debian)
#   T-B3  Linux glibc symbol version floor (objdump on pd-debian)
#   T-B5  macOS dynamic deps allowlist (otool -L locally)
#   T-B6  macOS minos = 11.0 (otool -l locally)
#   T-B7  share/openocd/scripts layout present in every archive
#   T-C1  openocd --version smoke run on every platform
#   T-C2  FT2232 + cJTAG/OScan1 config commands accepted (no hardware)
#   T-C3  CMSIS-DAP config command accepted (no hardware)
#   T-C4  script lookup resolves cfg from the RELEASE PACKAGE scripts dir
#         (-s points at the unpacked package, never a system install;
#          expected to fail at the USB stage, not at file lookup)
#
# Hardware-in-the-loop cases (T-H1..T-H5) run manually following the
# hpm-sdk-debug skill flow, with cfg files taken from HPM SDK
# boards/openocd/ and the probe/board selection confirmed by the user.
#
# Usage: verify-release-artifacts.sh <artifact-dir> [result-dir]
#   <artifact-dir>  directory holding the 4 archives + .sha256 files
#                   (as produced by actions/download-artifact)
#   [result-dir]    where to write logs (default: ../results/<timestamp>)

set -euo pipefail

ARTIFACT_DIR=${1:?usage: verify-release-artifacts.sh <artifact-dir> [result-dir]}
LINUX_HOST=ryan@pd-debian
WIN_HOST=ryan@10.211.55.3
WIN_TMP='C:/Users/ryan/ocd-verify'
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RESULT_DIR=${2:-${SCRIPT_DIR}/../results/$(date +%Y%m%d-%H%M)}
mkdir -p "$RESULT_DIR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

report() { # report <case-id> <PASS|FAIL> <detail>
    printf '%s %s %s\n' "$2" "$1" "$3" | tee -a "$RESULT_DIR/summary.txt"
    if [ "$2" = PASS ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
}

# ---------------------------------------------------------------- T-B1
for f in \
    openocd-linux-x86_64.tar.gz \
    openocd-windows-i686.zip \
    openocd-macos-arm64.tar.gz \
    openocd-macos-x86_64.tar.gz; do
    if [ -f "$ARTIFACT_DIR/$f" ] && [ -f "$ARTIFACT_DIR/$f.sha256" ]; then
        (cd "$ARTIFACT_DIR" && shasum -a 256 -c "$(basename "$f").sha256" \
            >> "$RESULT_DIR/sha256.log" 2>&1) \
            && report T-B1 PASS "sha256 $f" || report T-B1 FAIL "sha256 $f"
    else
        report T-B1 FAIL "missing $f or its .sha256"
    fi
done

# ---------------------------------------------------------------- unpack
mkdir -p "$WORK/linux" "$WORK/macos-arm64" "$WORK/macos-x86_64" "$WORK/windows"
tar -xzf "$ARTIFACT_DIR/openocd-linux-x86_64.tar.gz" -C "$WORK/linux"
tar -xzf "$ARTIFACT_DIR/openocd-macos-arm64.tar.gz" -C "$WORK/macos-arm64"
tar -xzf "$ARTIFACT_DIR/openocd-macos-x86_64.tar.gz" -C "$WORK/macos-x86_64"
unzip -q "$ARTIFACT_DIR/openocd-windows-i686.zip" -d "$WORK/windows"

# ---------------------------------------------------------------- T-B7
for plat in linux macos-arm64 macos-x86_64 windows; do
    if [ -d "$WORK/$plat/usr/share/openocd/scripts" ] && \
       ls "$WORK/$plat/usr/share/openocd/scripts/board" >/dev/null 2>&1; then
        report T-B7 PASS "$plat share/openocd/scripts layout"
    else
        report T-B7 FAIL "$plat share/openocd/scripts layout"
    fi
done

# ---------------------------------------------------------------- T-B5, T-B6
MACOS_ALLOW='^/usr/lib/|^/System/Library/'
for plat in macos-arm64 macos-x86_64; do
    BIN="$WORK/$plat/usr/local/bin/openocd"
    UNEXPECTED=$(otool -L "$BIN" | tail -n +2 | grep -vE "$MACOS_ALLOW" || true)
    [ -z "$UNEXPECTED" ] \
        && report T-B5 PASS "$plat only system frameworks" \
        || report T-B5 FAIL "$plat unexpected deps: $UNEXPECTED"
    MINOS=$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $3; exit}')
    [ "$MINOS" = "11.0" ] \
        && report T-B6 PASS "$plat minos 11.0" \
        || report T-B6 FAIL "$plat minos is '$MINOS' (expected 11.0)"
done

# ---------------------------------------------------------------- config-only cfg files (driver smoke, no scripts needed)
mkdir -p "$WORK/cfg"
cat > "$WORK/cfg/ftdi-oscan1.cfg" <<'EOF'
adapter driver ftdi
ftdi oscan1_mode on
shutdown
EOF
cat > "$WORK/cfg/cmsis-dap.cfg" <<'EOF'
adapter driver cmsis-dap
shutdown
EOF

# ---------------------------------------------------------------- macOS local smoke, x86_64 native
OCD="$WORK/macos-x86_64/usr/local/bin/openocd"
S="$WORK/macos-x86_64/usr/share/openocd/scripts"
"$OCD" --version > "$RESULT_DIR/version-macos-x86_64.txt" 2>&1 \
    && report T-C1 PASS "macos-x86_64 --version" \
    || report T-C1 FAIL "macos-x86_64 --version"
"$OCD" -f "$WORK/cfg/ftdi-oscan1.cfg" > /dev/null 2>&1 \
    && report T-C2 PASS "macos-x86_64 ftdi+oscan1 cfg" \
    || report T-C2 FAIL "macos-x86_64 ftdi+oscan1 cfg"
"$OCD" -f "$WORK/cfg/cmsis-dap.cfg" > /dev/null 2>&1 \
    && report T-C3 PASS "macos-x86_64 cmsis-dap cfg" \
    || report T-C3 FAIL "macos-x86_64 cmsis-dap cfg"
# -s forces the package scripts dir first so the cfg comes from the
# release package, never from a system openocd installation.
"$OCD" -s "$S" -f interface/ftdi/olimex-arm-usb-tiny-h.cfg \
    > "$RESULT_DIR/tc4-macos.txt" 2>&1 || true
if grep -qiE "unable to open|no such file|can't find|Can't find" "$RESULT_DIR/tc4-macos.txt"; then
    report T-C4 FAIL "macos-x86_64 script lookup broken (file not found)"
else
    report T-C4 PASS "macos-x86_64 cfg resolved from package scripts (USB-stage error expected)"
fi

# ---------------------------------------------------------------- Linux remote (pd-debian)
LINUX_RDIR="/tmp/ocd-verify-$$"
scp -q "$ARTIFACT_DIR/openocd-linux-x86_64.tar.gz" "$LINUX_HOST:/tmp/" && \
ssh "$LINUX_HOST" "rm -rf $LINUX_RDIR && mkdir -p $LINUX_RDIR && \
    tar -xzf /tmp/openocd-linux-x86_64.tar.gz -C $LINUX_RDIR" && \
LINUX_OK=1 || LINUX_OK=0
if [ "$LINUX_OK" = 1 ]; then
    LBIN="$LINUX_RDIR/usr/local/bin/openocd"
    LSCRIPTS="$LINUX_RDIR/usr/share/openocd/scripts"
    LDD_OUT=$(ssh "$LINUX_HOST" "ldd $LBIN")
    echo "$LDD_OUT" >> "$RESULT_DIR/ldd-linux.txt"
    UNEXPECTED=$(echo "$LDD_OUT" | grep -vE "linux-vdso|ld-linux-x86-64|libc\.so\.6|libudev\.so\.1|libm\.so\.6" || true)
    [ -z "$UNEXPECTED" ] \
        && report T-B2 PASS "linux ldd allowlist" \
        || report T-B2 FAIL "linux unexpected deps: $UNEXPECTED"
    GLIBC_MAX=$(ssh "$LINUX_HOST" \
        "objdump -T $LBIN | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1")
    echo "max glibc symbol: $GLIBC_MAX" >> "$RESULT_DIR/glibc-linux.txt"
    [ "$GLIBC_MAX" = "GLIBC_2.36" ] || [ "$GLIBC_MAX" \< "GLIBC_2.36" ] \
        && report T-B3 PASS "glibc floor $GLIBC_MAX" \
        || report T-B3 FAIL "glibc floor $GLIBC_MAX (expected <= 2.36)"
    ssh "$LINUX_HOST" "$LBIN --version" > "$RESULT_DIR/version-linux.txt" 2>&1 \
        && report T-C1 PASS "linux --version" || report T-C1 FAIL "linux --version"
    scp -q "$WORK/cfg/ftdi-oscan1.cfg" "$WORK/cfg/cmsis-dap.cfg" "$LINUX_HOST:$LINUX_RDIR/"
    ssh "$LINUX_HOST" "$LBIN -f $LINUX_RDIR/ftdi-oscan1.cfg" >/dev/null 2>&1 \
        && report T-C2 PASS "linux ftdi+oscan1 cfg" || report T-C2 FAIL "linux ftdi+oscan1 cfg"
    ssh "$LINUX_HOST" "$LBIN -f $LINUX_RDIR/cmsis-dap.cfg" >/dev/null 2>&1 \
        && report T-C3 PASS "linux cmsis-dap cfg" || report T-C3 FAIL "linux cmsis-dap cfg"
    ssh "$LINUX_HOST" "$LBIN -s $LSCRIPTS -f interface/ftdi/olimex-arm-usb-tiny-h.cfg" \
        > "$RESULT_DIR/tc4-linux.txt" 2>&1 || true
    if grep -qiE "unable to open|no such file|can't find|Can't find" "$RESULT_DIR/tc4-linux.txt" 2>/dev/null; then
        report T-C4 FAIL "linux script lookup broken (file not found)"
    else
        report T-C4 PASS "linux cfg resolved from package scripts (USB-stage error expected)"
    fi
else
    for c in T-B2 T-B3 T-C1 T-C2 T-C3 T-C4; do report "$c" FAIL "pd-debian unreachable/unpack failed"; done
fi

# ---------------------------------------------------------------- Windows remote (WoW64)
tar -czf "$WORK/openocd-win-bundle.tar.gz" -C "$WORK/windows" usr
scp -q "$WORK/openocd-win-bundle.tar.gz" "$WORK/cfg/ftdi-oscan1.cfg" "$WORK/cfg/cmsis-dap.cfg" \
    "$WIN_HOST:C:/Users/ryan/" && \
ssh "$WIN_HOST" "rmdir /s /q $WIN_TMP 2>nul & mkdir $WIN_TMP && \
    tar -xzf C:/Users/ryan/openocd-win-bundle.tar.gz -C $WIN_TMP && echo BUNDLE_OK" \
    > "$WORK/win-unpack.log" 2>&1 && grep -q BUNDLE_OK "$WORK/win-unpack.log" && WIN_OK=1 || WIN_OK=0
if [ "$WIN_OK" = 1 ]; then
    WBIN="$WIN_TMP/usr/bin/openocd.exe"
    WSCRIPTS="$WIN_TMP/usr/share/openocd/scripts"
    ssh "$WIN_HOST" "$WBIN --version" > "$RESULT_DIR/version-windows.txt" 2>&1 \
        && report T-C1 PASS "windows --version (WoW64)" \
        || report T-C1 FAIL "windows --version (WoW64)"
    ssh "$WIN_HOST" "$WBIN -f C:/Users/ryan/cmsis-dap.cfg" >/dev/null 2>&1 \
        && report T-C3 PASS "windows cmsis-dap cfg" || report T-C3 FAIL "windows cmsis-dap cfg"
    ssh "$WIN_HOST" "$WBIN -f C:/Users/ryan/ftdi-oscan1.cfg" >/dev/null 2>&1 \
        && report T-C2 PASS "windows ftdi+oscan1 cfg" || report T-C2 FAIL "windows ftdi+oscan1 cfg"
    WIN_TC4=$(ssh "$WIN_HOST" "$WBIN -s $WSCRIPTS -f interface/ftdi/olimex-arm-usb-tiny-h.cfg" 2>&1 || true)
    echo "$WIN_TC4" > "$RESULT_DIR/tc4-windows.txt"
    if echo "$WIN_TC4" | grep -qiE "unable to open|no such file|can't find|Can't find"; then
        report T-C4 FAIL "windows script lookup broken (file not found)"
    else
        report T-C4 PASS "windows cfg resolved from package scripts (USB-stage error expected)"
    fi
else
    for c in T-C1 T-C2 T-C3 T-C4; do report "$c" FAIL "windows host unreachable/unpack failed"; done
fi

# ---------------------------------------------------------------- summary
echo
echo "===== RESULT: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
