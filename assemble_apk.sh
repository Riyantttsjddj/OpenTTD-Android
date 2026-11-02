#!/bin/bash
#
# Assemble, align and sign the release APK.
#
# Run after the native build has produced libmain.so.  Everything it needs is
# derived from the tree it is run in, so it is safe to re-run: it rebuilds
# out/ from scratch each time and never touches the source trees.
#
# Two properties matter for a public release and are easy to get wrong:
#   * the APK is signed with the release key, not a debug key, and it is
#     zipaligned *before* signing (aligning afterwards invalidates the
#     signature);
#   * every native library is 16 KiB-page aligned.  Android 15+ devices with
#     16 KiB pages refuse to load a library aligned to 4 KiB, and this is not
#     something the build system does for you.
set -euo pipefail

BUILD=/root/build
APK=$BUILD/apk
OUT=$APK/out
NATIVE=$BUILD/android
PREFIX=$BUILD/prefix
KEYSTORE=$BUILD/keys/release.jks
KEY_ALIAS=openttd-unofficial

# Two framework jars, for two different jobs.
#
# android.jar (API 35) is what the Java code is compiled and dexed against: it
# supplies the android.* and org.json.* classes SDL's Java needs, and a modern
# one is required because the Java sources use APIs newer than the old jar has.
#
# LINK_JAR is what aapt2 is given as the resource include. The only aapt2 that
# runs on this host is Debian's build-tools 2.19, which cannot parse the
# resource table of a modern platform jar -- it fails with "entry offsets
# overlap actual entry data". The old jar's resource table it can read, and
# nothing in this app's resources refers to anything newer.
ANDROID_JAR=$BUILD/../android-sdk/sdk/platforms/android-35/android.jar
LINK_JAR=/usr/lib/android-sdk/platforms/android-23/android.jar
AAPT2=/usr/lib/android-sdk/build-tools/29.0.3/aapt2
D8_JAR=$BUILD/../android-sdk/sdk/cmdline-tools/latest/lib/r8.jar
LLVM_STRIP=/root/ndk-mirror/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip
LLVM_READELF=/root/ndk-mirror/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf

# Credentials for the release key.  Kept outside the repository, and outside
# the build tree, so a packaged source archive never carries them.
KEYSTORE_PASS=$(cat "$BUILD/keys/store.pass")
KEY_PASS=$(cat "$BUILD/keys/key.pass")

echo "== cleaning $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"/{compiled,gen,classes,dex,apk}

echo "== compiling resources"
"$AAPT2" compile --dir "$APK/res" -o "$OUT/compiled/res.zip"

echo "== linking resources"
"$AAPT2" link \
    -o "$OUT/apk/base.apk" \
    -I "$LINK_JAR" \
    --manifest "$APK/AndroidManifest.xml" \
    --java "$OUT/gen" \
    --min-sdk-version 24 \
    --target-sdk-version 34 \
    --no-static-lib-packages \
    --no-version-vectors \
    "$OUT/compiled/res.zip"

echo "== compiling java"
# android.jar goes on the ordinary classpath: -bootclasspath was removed in
# JDK 9, so there is no way to restrict javac's own idea of the platform to it.
# That means the compiler will happily accept JDK-only APIs -- Stream.toList(),
# for instance -- which then fail at runtime on the device.  The audit below is
# what actually keeps those out.
find "$APK/java" "$OUT/gen" -name '*.java' > "$OUT/sources.txt"
javac -source 8 -target 8 -nowarn \
    -classpath "$ANDROID_JAR" \
    -d "$OUT/classes" \
    @"$OUT/sources.txt"

echo "== auditing the compiled classes against android.jar"
# Every class the Java code references has to exist in android.jar, because that
# (plus the NDK's libc++ and the device's own libraries) is all the runtime has.
# A reference to a JDK class that Android never shipped compiles without
# complaint and then throws NoClassDefFoundError on the device.
unzip -l "$ANDROID_JAR" | awk '{print $4}' | grep '\.class$' | sed 's|\.class$||' | LC_ALL=C sort -u > "$OUT/platform-classes.txt"

javap -v -p $(find "$OUT/classes" -name '*.class') 2>/dev/null \
    | grep -oE '// [A-Za-z0-9_$]+(/[A-Za-z0-9_$]+)+' | awk '{print $2}' | LC_ALL=C sort -u > "$OUT/referenced.txt"

# Our own classes are not in android.jar and are expected not to be.
#
# java.lang.invoke is exempt for a different reason: it is not part of the
# Android public API, so nothing there is in android.jar either, but a lambda or
# a method reference compiles to an invokedynamic that names LambdaMetafactory,
# and String concatenation on a modern javac can name StringConcatFactory.  D8
# rewrites both away while dexing, because they do not exist below API 26, so
# they must not be present in the finished dex -- which the check after dexing
# enforces, and which is the assertion that actually matters.  SDL's own Java
# uses lambdas, so this exemption is required for its sources, not only ours.
grep -E '^(android|java|javax|junit|org)/' "$OUT/referenced.txt" \
    | grep -vE '^org/(libsdl|openttd)/' \
    | grep -vE '^java/lang/invoke/(LambdaMetafactory|StringConcatFactory)$' \
    > "$OUT/referenced-platform.txt" || true

comm -23 "$OUT/referenced-platform.txt" "$OUT/platform-classes.txt" > "$OUT/missing.txt"
if [ -s "$OUT/missing.txt" ]; then
    echo "ERROR: these are referenced but not available on Android:"
    sed 's/^/   /' "$OUT/missing.txt"
    exit 1
fi
echo "   all $(wc -l < "$OUT/referenced-platform.txt") referenced platform classes are present in android.jar"

echo "== dexing"
java -cp "$D8_JAR" com.android.tools.r8.D8 \
    --release \
    --min-api 24 \
    --lib "$ANDROID_JAR" \
    --output "$OUT/dex" \
    $(find "$OUT/classes" -name '*.class')

echo "== checking the dex for APIs the platform does not have"
# The audit before dexing can only say what the Java sources reference, and it
# has to let java.lang.invoke through because D8 is what removes it.  This is the
# assertion that matters: the desugared dex must name nothing the platform lacks.
# Anything left here -- an un-desugared lambda, a StringConcatFactory, a JDK-only
# class -- would throw at class-load time on the device and take the app down
# before it draws anything.
if strings "$OUT/dex/classes.dex" | grep -qE 'java/lang/invoke/(LambdaMetafactory|StringConcatFactory)'; then
    echo "ERROR: classes.dex still refers to an invokedynamic bootstrap the platform has no implementation of"
    strings "$OUT/dex/classes.dex" | grep -E 'java/lang/invoke/(LambdaMetafactory|StringConcatFactory)' | sort -u | sed 's/^/   /'
    exit 1
fi
echo "   no undesugared java.lang.invoke references in classes.dex"

echo "== staging native libraries"
# The two ABIs the APK ships: arm64-v8a (the modern one, must be 16 KiB page
# aligned) and armeabi-v7a (32-bit).  Each comes from its own build tree and
# dependency prefix so the two never clobber each other.
SYSROOT=/root/ndk-mirror/toolchains/llvm/prebuilt/linux-x86_64/sysroot

stage_abi() {
    local abi=$1 native=$2 prefix=$3 cxx=$4
    mkdir -p "$OUT/apk/lib/$abi"
    for lib in "$native/libmain.so" "$prefix/lib/libSDL2.so"; do
        name=$(basename "$lib")
        cp "$lib" "$OUT/apk/lib/$abi/$name"
        "$LLVM_STRIP" --strip-unneeded "$OUT/apk/lib/$abi/$name"
    done
    # libc++ is shared because SDL2 and the game are separate shared objects
    # that must agree on one C++ runtime; a mismatch here shows up as crashes on
    # the first std::string that crosses the boundary.
    cp "$SYSROOT/usr/lib/$cxx/libc++_shared.so" "$OUT/apk/lib/$abi/"
    "$LLVM_STRIP" --strip-unneeded "$OUT/apk/lib/$abi/libc++_shared.so"
}

stage_abi arm64-v8a   "$NATIVE"         "$PREFIX"         aarch64-linux-android
stage_abi armeabi-v7a "$BUILD/android-armv7" "$BUILD/prefix-armv7" arm-linux-androideabi

echo "== checking 16 KiB page alignment"
# The alignment is set by the linker at build time, not here: it lives in the
# program headers, which cannot be changed afterwards.  This verifies that both
# arm64 libraries actually got it, because a library left at 4 KiB is refused at
# load time on Android 15 devices that use 16 KiB pages -- a failure that only
# shows up on those devices, and only as a refusal to start.  32-bit armv7 has
# no 16 KiB page devices, so no such check applies to it.
for lib in "$OUT/apk/lib/arm64-v8a/libmain.so" "$OUT/apk/lib/arm64-v8a/libSDL2.so"; do
    align=$("$LLVM_READELF" -lW "$lib" | awk '/^  LOAD/ { print $NF }' | sort -u | tr '\n' ' ')
    case "$align" in
        *0x4000*) echo "   $(basename "$lib"): $align" ;;
        *) echo "ERROR: $(basename "$lib") is not 16 KiB aligned (got: $align)"; exit 1 ;;
    esac
done

echo "== packaging dex, native libraries and assets"
# aapt2 link produced an APK holding only the manifest, resources and icons.
# The dex, the native libraries and the game data have to be added to *that*
# file: writing them alongside it and then aligning it would ship an APK with
# none of them in it, which signs and installs and then fails at once.
#
# They go in before zipalign, because zipalign rewrites the archive and anything
# added after it would be left unaligned.
if [ -z "$(ls -A "$APK/assets/game" 2>/dev/null)" ]; then
    echo "ERROR: $APK/assets/game is empty -- run stage_assets.sh before assembling,"
    echo "       otherwise the APK has no game data and cannot start."
    exit 1
fi
mkdir -p "$OUT/apk/assets"
cp -a "$APK/assets/game" "$OUT/apk/assets/game"
cp "$OUT/dex/classes.dex" "$OUT/apk/classes.dex"
( cd "$OUT/apk" && zip -q -X -r base.apk classes.dex lib assets )

# zip reports a missing input as a warning and still exits 0, so a typo here
# produces an APK that installs and then cannot find its own activity class.
# Check what actually landed in the archive rather than trusting the exit code.
for required in classes.dex AndroidManifest.xml resources.arsc \
                lib/arm64-v8a/libmain.so lib/arm64-v8a/libSDL2.so \
                lib/arm64-v8a/libc++_shared.so \
                lib/armeabi-v7a/libmain.so lib/armeabi-v7a/libSDL2.so \
                lib/armeabi-v7a/libc++_shared.so; do
    if ! unzip -l "$OUT/apk/base.apk" "$required" 2>/dev/null | grep -qF "$required"; then
        echo "ERROR: $required is missing from the packaged APK"
        exit 1
    fi
done
echo "   classes.dex and all six native libraries are in the archive"

echo "== zipaligning"
zipalign -f -p 4 "$OUT/apk/base.apk" "$OUT/apk/aligned.apk"

echo "== signing"
apksigner sign \
    --ks "$KEYSTORE" \
    --ks-key-alias "$KEY_ALIAS" \
    --ks-pass "pass:$KEYSTORE_PASS" \
    --key-pass "pass:$KEY_PASS" \
    --v1-signing-enabled true \
    --v2-signing-enabled true \
    --v3-signing-enabled true \
    --out "$APK/OpenTTD-16.0-android.apk" \
    "$OUT/apk/aligned.apk"

echo "== verifying"
apksigner verify --verbose --print-certs "$APK/OpenTTD-16.0-android.apk"

ls -la "$APK/OpenTTD-16.0-android.apk"
