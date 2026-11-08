#!/usr/bin/env bash
# Native Apple SDK and genuine open-source XNU 8796 configuration/bootstrap compilation.
# No device operations or Apple proprietary firmware.
set -u
ART="$GITHUB_WORKSPACE/xnu-macos-results"
ROOT="$GITHUB_WORKSPACE/upstream-xnu"
mkdir -p "$ART/config-build" "$ART/generated" "$ART/headers/sys"
cd "$ROOT" || exit 1
git rev-parse HEAD | tee "$ART/source-commit.txt"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
echo "SDK=$SDKROOT" | tee "$ART/host.log"
xcodebuild -version | tee -a "$ART/host.log"
xcrun clang --version | head -2 | tee -a "$ART/host.log"
ls -l "$SDKROOT/usr/include/sys/_symbol_aliasing.h" >>"$ART/host.log" 2>&1 || true
cd "$ART/config-build" || exit 1
cp "$ROOT"/SETUP/config/{main.c,mkheaders.c,mkioconf.c,mkmakefile.c,externs.c,openp.c,searchp.c,parser.y,lexer.l,config.h} .
echo "ORIGINAL APPLE CONFIG BUILDER" | tee "$ART/config.log"
BISON="$(command -v bison)"
FLEX="$(command -v flex)"
if command -v brew >/dev/null 2>&1; then
  HOMEBREW="$(brew --prefix)"
  if [ -x "$HOMEBREW/opt/bison/bin/bison" ]; then BISON="$HOMEBREW/opt/bison/bin/bison"; fi
  if [ -x "$HOMEBREW/opt/flex/bin/flex" ]; then FLEX="$HOMEBREW/opt/flex/bin/flex"; fi
fi
"$BISON" -y -d -o parser.c parser.y >>"$ART/config.log" 2>&1
BISON_RC=$?
"$FLEX" -o lexer.yy.c lexer.l >>"$ART/config.log" 2>&1
FLEX_RC=$?
echo "BISON=$BISON_RC FLEX=$FLEX_RC" | tee -a "$ART/config.log"
if [ "$BISON_RC" -ne 0 ] || [ "$FLEX_RC" -ne 0 ]; then exit 11; fi
xcrun clang -std=gnu11 -O0 -I. -DYY_NO_INPUT -o config \
  externs.c main.c mkheaders.c mkioconf.c mkmakefile.c openp.c searchp.c lexer.yy.c parser.c \
  >>"$ART/config.log" 2>&1
CC_RC=$?
echo "CONFIG_CC=$CC_RC" | tee -a "$ART/config.log"
if [ "$CC_RC" -ne 0 ]; then exit 12; fi
mkdir -p "$ART/generated/SETUP/config"
cp config "$ART/generated/SETUP/config/config"
cd "$ROOT" || exit 1
export OBJROOT="$ART/generated" SRCROOT="$ROOT" SOURCE="$ROOT"
echo "APPLE DOCONF" | tee "$ART/doconf.log"
/bin/csh -f SETUP/config/doconf -c -cpu arm64 -soc bcm2837 -platform xnu \
  -d "$ART/generated" -m "$ROOT/config" -s "$ROOT/osfmk/conf" DEVELOPMENT \
  >>"$ART/doconf.log" 2>&1
DOC_RC=$?
echo "DOCONF=$DOC_RC" | tee -a "$ART/doconf.log"
find "$ART/generated" -maxdepth 2 -type f | sort > "$ART/generated-files.txt"
if [ "$DOC_RC" -ne 0 ] || [ ! -s "$ART/generated/mach_assert.h" ] || [ ! -s "$ART/generated/mach_ldebug.h" ]; then
  echo "FAIL: missing original generated headers" | tee -a "$ART/doconf.log"
  exit 13
fi
if [ ! -f "$SDKROOT/usr/include/sys/_symbol_aliasing.h" ]; then
  echo "SDK header not present: invoke original XNU sys/make_symbol_aliasing.sh" | tee "$ART/symbol-aliasing.log"
  bash "$ROOT/bsd/sys/make_symbol_aliasing.sh" "$SDKROOT" "$ART/headers/sys/_symbol_aliasing.h" >>"$ART/symbol-aliasing.log" 2>&1
  echo "ORIGINAL_ALIAS_GENERATOR_RC=$?" | tee -a "$ART/symbol-aliasing.log"
else
  echo "Using authentic macOS SDK symbol alias header" | tee "$ART/symbol-aliasing.log"
fi
INCLUDES="-I $ART/generated -I $ART/headers -I $ROOT/bsd -I $ROOT/osfmk -I $ROOT/pexpert -I $SDKROOT/usr/include -I $ROOT/EXTERNAL_HEADERS -I $ROOT/libkern -I $ROOT/iokit -I $ROOT/libsa"
FLAGS="-target arm64-apple-macos11.0 -isysroot $SDKROOT -march=armv8-a -D__arm64__=1 -DARM64_BOARD_CONFIG_BCM2837=1 -DPLATFORM_XNU=1 -DKERNEL=1 -D_KERNEL=1 -fno-integrated-as -include stdbool.h -include $SDKROOT/usr/include/Availability.h"
echo "COMPILING GENUINE APPLE XNU GENASSYM.C" | tee "$ART/genassym.log"
xcrun clang $FLAGS $INCLUDES -S "$ROOT/osfmk/arm64/genassym.c" -o "$ART/genassym-compiler.s" >>"$ART/genassym.log" 2>&1
GEN_RC=$?
echo "GENASSYM_RC=$GEN_RC" | tee -a "$ART/genassym.log"
if [ "$GEN_RC" -eq 0 ]; then
  echo "GENERATING ASSYM.S USING ORIGINAL APPLE BUILD SED RULE" | tee "$ART/assym.log"
  sed -e '/^[[:space:]]*DEFINITION__define__/!d;{N;s/\n//;}' \
    -e 's/^[[:space:]]*DEFINITION__define__\([^:]*\):.*ascii.*\"[\$]*\([-0-9\#]*\)\".*$/#define \1 \2/' \
    -e 'p' -e 's/#//2' \
    -e 's/^[[:space:]]*#define \([A-Za-z0-9_]*\)[[:space:]]*[\$#]*\([-0-9]*\).*$/#define \1_NUM \2/' \
    "$ART/genassym-compiler.s" >"$ART/generated/assym.s"
  echo "COUNT=$(grep -c '^#define' "$ART/generated/assym.s" || true)" | tee -a "$ART/assym.log"
  head -n12 "$ART/generated/assym.s" | tee -a "$ART/assym.log"
else
  echo "BLOCKED ASSYM: GENASSYM NOT COMPILED" | tee "$ART/assym.log"
fi
echo "COMPILING GENUINE APPLE XNU START.S" | tee "$ART/start.log"
if [ -s "$ART/generated/assym.s" ]; then
  xcrun clang $FLAGS $INCLUDES -x assembler-with-cpp -D__ASSEMBLER__=1 \
    -c "$ROOT/osfmk/arm64/start.s" -o "$ART/start-arm64.o" >>"$ART/start.log" 2>&1
  START_RC=$?
else
  START_RC=90
  echo "BLOCKED: original assym.s not generated" >>"$ART/start.log"
fi
echo "START_RC=$START_RC" | tee -a "$ART/start.log"
tail -n55 "$ART/genassym.log"
tail -n55 "$ART/start.log"
if [ "$GEN_RC" -ne 0 ] || [ "$START_RC" -ne 0 ]; then exit 14; fi
echo "PASS: GENUINE XNU GENASSYM + ASSYM.S + START.S"
