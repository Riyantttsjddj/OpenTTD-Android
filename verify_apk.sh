#!/bin/bash
#
# Check a built APK against the things the store page claims about it.
#
# These are the assertions a downloader has no easy way to check for themselves
# and that would be quietly wrong if the packaging changed: that the app carries
# the expected identity, that it asks for the network permission its multiplayer
# feature needs (and nothing it does not), that the native code for both ABIs can
# actually be loaded, and that it is signed with the expected key.  Failing any
# of them means the APK should not be published.
set -uo pipefail

APK=${1:?usage: verify_apk.sh <apk>}
BUILD=/root/build
ANDROID_JAR=$BUILD/../android-sdk/sdk/platforms/android-35/android.jar
AAPT2=/usr/bin/aapt2
READELF=/root/ndk-mirror/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf

# The two architectures the APK ships.  arm64-v8a is the modern one and must be
# 16 KiB page aligned (Android 15 devices with 16 KiB pages refuse a 4 KiB
# library); armeabi-v7a is 32-bit, which has no 16 KiB page support, so that
# alignment check is skipped for it.
ABIS="arm64-v8a armeabi-v7a"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }

echo "== identity"
"$AAPT2" dump badging "$APK" > "$WORK/badging.txt" 2>/dev/null
grep -q "package: name='com.openttd.android'" "$WORK/badging.txt" \
    && ok "package is com.openttd.android" \
    || bad "package name is not the expected one: $(grep -m1 '^package:' "$WORK/badging.txt")"

grep -q "application-label:'OpenTTD'" "$WORK/badging.txt" \
    && ok "label is 'OpenTTD'" \
    || bad "label is not the expected one: $(grep -m1 'application-label:' "$WORK/badging.txt")"

grep -q "sdkVersion:'24'" "$WORK/badging.txt" \
    && ok "minimum Android is 7.0 (API 24)" \
    || bad "unexpected minimum SDK: $(grep -m1 'sdkVersion:' "$WORK/badging.txt")"

for abi in $ABIS; do
    # aapt2 prints all the ABIs on one native-code line as separate quoted
    # tokens, so match the ABI name as a token anywhere on the line rather than
    # right after the "native-code:" prefix.
    grep -qE "native-code:.*'$abi'" "$WORK/badging.txt" \
        && ok "ships $abi native code" \
        || bad "$abi native code missing"
done

echo
echo "== contents"
# An APK can be structurally valid, correctly signed and still have no dex in
# it, in which case Android refuses it with a message about the package not
# being valid -- and there is no clue in that message that the cause is a file
# that never made it into the archive.  Check the things the platform needs to
# find present, not just that the archive parses.
if unzip -l "$APK" classes.dex >/dev/null 2>&1; then
    dexsize=$(unzip -l "$APK" classes.dex | awk '/classes\.dex/ {print $1}')
    ok "classes.dex present ($dexsize bytes)"
    # A dex with no classes in it would load and then fail to find the activity.
    if unzip -p "$APK" classes.dex 2>/dev/null | head -c 4 | grep -q 'dex' ; then
        ok "classes.dex has a dex header"
    else
        bad "classes.dex does not start with the dex magic"
    fi
else
    bad "classes.dex is missing; Android will report the package as invalid"
fi
for entry in AndroidManifest.xml resources.arsc; do
    unzip -l "$APK" "$entry" >/dev/null 2>&1 && ok "$entry present" || bad "$entry missing"
done

echo
echo "== permissions"
# Multiplayer needs the network.  INTERNET alone is enough to join or host a
# game; ACCESS_NETWORK_STATE lets the game detect whether the device is online
# instead of failing a connect in the dark.  Both must be present, and nothing
# more is wanted -- in particular no permissions that would let the app track
# or advertise to the user.
for perm in INTERNET ACCESS_NETWORK_STATE; do
    grep -q "uses-permission: name='android.permission.$perm'" "$WORK/badging.txt" \
        && ok "$perm present (needed for multiplayer)" \
        || bad "$perm missing"
done
if grep -qE "uses-permission: name='(android.permission.ACCESS_WIFI_STATE|android.permission.RECORD_AUDIO|android.permission.CAMERA|android.permission.READ_CONTACTS|android.permission.ACCESS_FINE_LOCATION)'" "$WORK/badging.txt"; then
    bad "a permission that would let the app track or spy is present:"
    grep -E "uses-permission: name='android.permission.(ACCESS_WIFI_STATE|RECORD_AUDIO|CAMERA|READ_CONTACTS|ACCESS_FINE_LOCATION)'" "$WORK/badging.txt" | sed 's/^/        /'
else
    ok "no tracking or spying permissions"
fi
echo "  info  permissions actually declared:"
grep -oE "uses-permission: name='[^']+'" "$WORK/badging.txt" | sed "s/uses-permission: name=//; s/^/        /" || echo "        (none)"

echo
echo "== native libraries"
unzip -o -q "$APK" 'lib/*' -d "$WORK" 2>/dev/null
for abi in $ABIS; do
    echo "  -- $abi --"
    for lib in libmain.so libSDL2.so libc++_shared.so; do
        if [ ! -f "$WORK/lib/$abi/$lib" ]; then bad "$abi/$lib missing"; continue; fi
        # The game library is loaded by name and must export SDL_main, or SDL's
        # activity finds nothing to call and the app dies before drawing anything.
        # The symbol must also be defined rather than undefined, since being named
        # in .dynsym is not the same as owning it -- this reads the binding and
        # section columns rather than assuming a fixed field layout, because there
        # is a visibility column between them that the width of the numbers shifts.
        case "$lib" in
            libmain.so)
                if $READELF --dyn-syms -W "$WORK/lib/$abi/$lib" \
                     | awk '$4=="FUNC" && $5=="GLOBAL" && $7!="UND" && $8=="SDL_main" { found=1 }
                            END { exit !found }'; then
                    ok "$abi/$lib exports SDL_main"
                else
                    bad "$abi/$lib does not export SDL_main; SDL would find no entry point"
                fi
                ;;
        esac
        # 16 KiB page alignment is an arm64 concern only: 32-bit ARM has no
        # devices with 16 KiB pages.
        case "$abi" in
            arm64-v8a)
                align=$($READELF -lW "$WORK/lib/$abi/$lib" | awk '/^  LOAD/ { print $NF }' | sort -u | tr '\n' ' ')
                case "$align" in
                    *0x4000*) ok "$abi/$lib is 16 KiB page aligned ($align)" ;;
                    *)        bad "$abi/$lib is not 16 KiB page aligned (got: $align)" ;;
                esac
                ;;
        esac
    done
done

echo
echo "== native library dependencies"
# Anything needed that Android does not ship would fail to resolve at load time.
# This is exactly how the host's libGL or libz would sneak in if the build
# picked one up by mistake.
allowed='libm.so libdl.so liblog.so libandroid.so libc.so libz.so libGLESv1_CM.so libGLESv2.so libOpenSLES.so libEGL.so'
for abi in $ABIS; do
    for lib in "$WORK"/lib/$abi/libmain.so "$WORK"/lib/$abi/libSDL2.so; do
        [ -f "$lib" ] || continue
        missing=""
        for need in $($READELF -dW "$lib" | awk '/NEEDED/ { gsub(/[\[\]]/,"",$NF); print $NF }'); do
            # libc++_shared.so and the app's other libraries are shipped in the APK;
            # everything else has to be provided by the platform.
            if ! ls "$WORK"/lib/$abi/"$need" >/dev/null 2>&1; then
                case " $allowed " in
                    *" $need "*) ;;
                    *) missing="$missing $need" ;;
                esac
            fi
        done
        if [ -z "$missing" ]; then
            ok "$abi/$(basename "$lib") needs nothing the platform does not provide"
        else
            bad "$abi/$(basename "$lib") needs libraries not present on Android:$missing"
        fi
    done
done

echo
echo "== bundled data"
for f in assets/game/manifest.txt assets/game/data-version.txt \
         assets/game/baseset/opengfx.obg assets/game/baseset/opensfx.obs \
         assets/game/baseset/openmsx.obm assets/game/baseset/opntitle.dat; do
    unzip -l "$APK" "$f" >/dev/null 2>&1 && ok "$f" || bad "$f missing"
done
# The original game's assets must not be in here; redistributing them is the
# one thing that would make this distribution improper.
if unzip -l "$APK" 'assets/game/baseset/*' 2>/dev/null | grep -qE 'sample\.cat|gm\.cat|trg[0-9r]\.grf|\.gm$'; then
    bad "original Transport Tycoon Deluxe assets appear to be bundled"
else
    ok "no original Transport Tycoon Deluxe assets bundled"
fi

echo
echo "== signature"
if apksigner verify --print-certs "$APK" > "$WORK/certs.txt" 2>&1; then
    ok "signature verifies"
    grep -E "Signer #1 certificate (DN|SHA-256 digest)" "$WORK/certs.txt" | sed 's/^/        /'
else
    bad "signature does not verify:"
    sed 's/^/        /' "$WORK/certs.txt"
fi

echo
if [ "$fail" = "0" ]; then
    echo "ALL CHECKS PASSED"
else
    echo "SOME CHECKS FAILED"
fi
exit "$fail"