#!/usr/bin/env bash
# Build ORIGINAL Apple XNU 8796 configuration generator and attempt ARM64 startup.
# Original source is fetched by CI. This script does NOT fabricate option headers.
set -u
mkdir -p "$GITHUB_WORKSPACE/xnu-config-artifacts"
ART="$GITHUB_WORKSPACE/xnu-config-artifacts"
ROOT="$GITHUB_WORKSPACE/upstream-xnu"
cd "$ROOT" || exit 1
printf 'SOURCE_COMMIT=' | tee "$ART/provenance.log"
git rev-parse HEAD | tee -a "$ART/provenance.log"
mkdir -p "$ART/generated" "$ART/build-config"
cp SETUP/config/{main.c,mkheaders.c,mkioconf.c,mkmakefile.c,externs.c,openp.c,searchp.c,parser.y,lexer.l,config.h} "$ART/build-config/"
cd "$ART/build-config" || exit 1

# Make real parser/lexer from the XNU originals, not stubs.
echo "=== BISON / FLEX ===" | tee "$ART/config-tool.log"
bison -y -d -o parser.c parser.y >>"$ART/config-tool.log" 2>&1
BISON_RC=$?
flex --header-file=lexer.yy.h -o lexer.yy.c lexer.l >>"$ART/config-tool.log" 2>&1
FLEX_RC=$?
echo "bison=$BISON_RC flex=$FLEX_RC" | tee -a "$ART/config-tool.log"
if [[ "$BISON_RC" -ne 0 || "$FLEX_RC" -ne 0 ]]; then exit 10; fi
gcc -DYY_NO_INPUT -std=gnu11 -O0 -I. -o config \
  externs.c main.c mkheaders.c mkioconf.c mkmakefile.c \
  openp.c searchp.c lexer.yy.c parser.c >>"$ART/config-tool.log" 2>&1
GCC_RC=$?
echo "host_config_compiler=$GCC_RC" | tee -a "$ART/config-tool.log"
if [[ "$GCC_RC" -ne 0 ]]; then exit 11; fi

# Run Apple's original doconf script. It generates config.<name> and .h files.
mkdir -p "$ART/generated/SETUP/config"
cp config "$ART/generated/SETUP/config/config"
cd "$ROOT" || exit 1
export SRCROOT="$ROOT"
export OBJROOT="$ART/generated"
export SOURCE="$ROOT"
echo "=== APPLE DOCONF ARM64 BCM2837 DEVELOPMENT ===" | tee "$ART/doconf.log"
csh -f SETUP/config/doconf \
  -c -cpu arm64 -soc bcm2837 -platform xnu \
  -d "$ART/generated" -m "$ROOT/config" -s "$ROOT/osfmk/conf" DEVELOPMENT \
  >>"$ART/doconf.log" 2>&1
DOCONF_RC=$?
echo "doconf_exit=$DOCONF_RC" | tee -a "$ART/doconf.log"
  echo "=== DOCONF TRACE ==="; tail -n 90 "$ART/doconf.log" || true
  echo "=== GENERATED FILES ==="; find "$ART/generated" -maxdepth 2 -type f -printf "%P\n" | head -n 55
find "$ART/generated" -maxdepth 3 -type f | sort > "$ART/generated-files.txt"
find "$ART/generated" -name mach_assert.h -o -name mach_ldebug.h | tee "$ART/generated-headers.txt"
if [[ "$DOCONF_RC" -ne 0 ]]; then exit 12; fi
if [[ ! -s "$ART/generated/mach_assert.h" || ! -s "$ART/generated/mach_ldebug.h" ]]; then
  echo "EXPECTED GENERATED HEADERS MISSING: original config did not complete" | tee -a "$ART/doconf.log"
  exit 12
fi

# Compile the original Apple .s once with generated headers.
# The 4K page constants are from the original BCM2837 board config.
echo "=== ORIGINAL XNU START.S ARM64 COMPILE ===" | tee "$ART/start-compile.log"
clang --target=arm64-apple-darwin \
  -x assembler-with-cpp -march=armv8-a \
  -D__arm64__=1 -D__ASSEMBLER__=1 -DARM64_BOARD_CONFIG_BCM2837 \
  -I "$ART/generated" -I "$ROOT/osfmk" -I "$ROOT/pexpert" \
  -I "$ROOT/bsd" -I "$ROOT/EXTERNAL_HEADERS" \
  -c "$ROOT/osfmk/arm64/start.s" -o "$ART/start-arm64.o" \
  >>"$ART/start-compile.log" 2>&1
START_RC=$?
echo "start_s_exit=$START_RC" | tee -a "$ART/start-compile.log"
  echo "=== START.S FIRST ERRORS ==="; tail -n 75 "$ART/start-compile.log" || true

echo "=== ORIGINAL XNU GENASSYM.C ARM64 COMPILE ===" | tee "$ART/genassym-compile.log"
clang --target=aarch64-none-elf -march=armv8-a \
  -ffreestanding -D__arm64__=1 -DARM64_BOARD_CONFIG_BCM2837 \
  -I "$ART/generated" -I "$ROOT/osfmk" -I "$ROOT/pexpert" \
  -I "$ROOT/bsd" -I "$ROOT/EXTERNAL_HEADERS" \
  -c "$ROOT/osfmk/arm64/genassym.c" -o "$ART/genassym-aarch64.o" \
  >>"$ART/genassym-compile.log" 2>&1
GEN_RC=$?
echo "genassym_exit=$GEN_RC" | tee -a "$ART/genassym-compile.log"
  echo "=== GENASSYM.C FIRST ERRORS ==="; tail -n 75 "$ART/genassym-compile.log" || true
if [[ "$START_RC" -ne 0 || "$GEN_RC" -ne 0 ]]; then exit 13; fi
echo "ACTUAL_XNU_START_AND_GENASSYM_OBJECTS_BUILT"
