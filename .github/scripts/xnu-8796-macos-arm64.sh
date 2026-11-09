#!/usr/bin/env bash
# Build authentic Apple XNU 8796 arm64 genassym -> assym.s -> start.s.
# This is a compiler diagnostic pipeline, NOT a kernel image or phone boot.
set -u
ROOT="$GITHUB_WORKSPACE/upstream-xnu"
ART="$GITHUB_WORKSPACE/xnu-macos-build"
mkdir -p "$ART"/config-src "$ART"/generated
printf 'xnu_commit=' > "$ART/commit.txt"
git -C "$ROOT" rev-parse HEAD >> "$ART/commit.txt"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --find clang)"
echo "SDK=$SDK" >> "$ART/commit.txt"
"$CLANG" --version | head -n1 | tee "$ART/toolchain.log"

cd "$ART/config-src" || exit 70
cp "$ROOT"/SETUP/config/{main.c,mkheaders.c,mkioconf.c,mkmakefile.c,externs.c,openp.c,searchp.c,parser.y,lexer.l,config.h} .
bison -y -d -o parser.c parser.y > "$ART/config-tool.log" 2>&1
BISON_RC=$?
flex --header-file=lexer.yy.h -o lexer.yy.c lexer.l >> "$ART/config-tool.log" 2>&1
FLEX_RC=$?
printf 'bison_rc=%d flex_rc=%d\n' "$BISON_RC" "$FLEX_RC" | tee -a "$ART/config-tool.log"
if [ "$BISON_RC" -ne 0 ] || [ "$FLEX_RC" -ne 0 ]; then exit 71; fi
"$CLANG" -DYY_NO_INPUT -O0 -I. -o config \
  externs.c main.c mkheaders.c mkioconf.c mkmakefile.c openp.c searchp.c lexer.yy.c parser.c \
  >> "$ART/config-tool.log" 2>&1
COMPILER_RC=$?
echo "original_host_config_rc=$COMPILER_RC" | tee -a "$ART/config-tool.log"
if [ "$COMPILER_RC" -ne 0 ]; then exit 72; fi

mkdir -p "$ART/generated/SETUP/config"
cp config "$ART/generated/SETUP/config/config"
export SRCROOT="$ROOT"
export OBJROOT="$ART/generated"
export SOURCE="$ROOT"
cd "$ROOT" || exit 73
echo '=== Original Apple XNU ARM64 BCM2837 DEVELOPMENT configuration ===' > "$ART/doconf.log"
csh -f SETUP/config/doconf -c -cpu arm64 -soc bcm2837 -platform xnu \
  -d "$ART/generated" -m "$ROOT/config" -s "$ROOT/osfmk/conf" DEVELOPMENT \
  >> "$ART/doconf.log" 2>&1
DOCONF_RC=$?
echo "doconf_rc=$DOCONF_RC" | tee -a "$ART/doconf.log"
find "$ART/generated" -maxdepth 3 -type f | sort > "$ART/generated-files.txt"
for name in mach_assert.h mach_ldebug.h; do
  if [ ! -s "$ART/generated/$name" ]; then
    echo "GENUINE_HEADER_NOT_PRODUCED=$name" | tee -a "$ART/doconf.log"
    exit 74
  fi
  echo "GENERATED_ORIGINAL_OPTION_HEADER=$name" | tee -a "$ART/doconf.log"
  sed -n '1,5p' "$ART/generated/$name" | tee -a "$ART/doconf.log"
done
if [ "$DOCONF_RC" -ne 0 ]; then exit 75; fi

# Original architecture code needs SDK headers, e.g. sys/_symbol_aliasing.h.
INCLUDES="-I$ART/generated -I$ROOT/osfmk -I$ROOT/osfmk/mach -I$ROOT/pexpert -I$ROOT/bsd -I$ROOT/libkern -I$ROOT/libsa -I$ROOT/iokit -I$ROOT/EXTERNAL_HEADERS"
echo "=== Compile genuine XNU genassym.c to ARM64 assembly ===" > "$ART/genassym-compile.log"
"$CLANG" -target arm64-apple-ios16.0 -isysroot "$SDK" \
  -x c -std=gnu11 -O0 -ffreestanding -S \
  -D__arm64__=1 -DARM64_BOARD_CONFIG_BCM2837 -DMACH_KERNEL=1 -DMACH_KERNEL_PRIVATE=1 \
  $INCLUDES -o "$ART/genassym.o" "$ROOT/osfmk/arm64/genassym.c" \
  >> "$ART/genassym-compile.log" 2>&1
GENASSYM_RC=$?
echo "genassym_asm_rc=$GENASSYM_RC" | tee -a "$ART/genassym-compile.log"
if [ "$GENASSYM_RC" -ne 0 ]; then
  echo "FIRST_GENASSYM_ERRORS:"; tail -n 45 "$ART/genassym-compile.log"
  exit 76
fi

# Exact definition extraction in xnu/osfmk/conf/Makefile.template.
sed -e '/^[[:space:]]*DEFINITION__define__/!d;{N;s/\n//;}' \
  -e 's/^[[:space:]]*DEFINITION__define__\([^:]*\):.*ascii.*"[\$]*\([-0-9\#]*\)".*$/#define \1 \2/' \
  -e 'p' \
  -e 's/#//2' \
  -e 's/^[[:space:]]*#define \([A-Za-z0-9_]*\)[[:space:]]*[\$#]*\([-0-9]*\).*$/#define \1_NUM \2/' \
  "$ART/genassym.o" > "$ART/generated/assym.s"
echo "ASSYM_LINES=$(wc -l < "$ART/generated/assym.s")" | tee "$ART/assym-generation.log"
head -n 10 "$ART/generated/assym.s" | tee -a "$ART/assym-generation.log"
if [ ! -s "$ART/generated/assym.s" ]; then exit 77; fi

echo "=== Compile authentic XNU start.s to Mach-O ARM64 ===" > "$ART/start-compile.log"
"$CLANG" -target arm64-apple-ios16.0 -isysroot "$SDK" \
  -x assembler-with-cpp -c -march=armv8-a \
  -D__arm64__=1 -D__ASSEMBLER__=1 -DARM64_BOARD_CONFIG_BCM2837 \
  $INCLUDES -o "$ART/start-arm64.o" "$ROOT/osfmk/arm64/start.s" \
  >> "$ART/start-compile.log" 2>&1
START_RC=$?
echo "start_s_rc=$START_RC" | tee -a "$ART/start-compile.log"
if [ "$START_RC" -ne 0 ]; then
  echo "FIRST_START_ERRORS:"; tail -n 45 "$ART/start-compile.log"
  exit 78
fi
file "$ART/start-arm64.o" | tee "$ART/final-build.txt"
shasum -a 256 "$ART/start-arm64.o" | tee -a "$ART/final-build.txt"
echo "AUTHENTIC_XNU_8796_GENASSYM_AND_START_S_BUILT_NOT_KERNEL_BOOT"
