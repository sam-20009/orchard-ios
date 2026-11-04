#!/usr/bin/env python3
"""Apply narrowly scoped defensive fixes to the pinned Husk 3.3 C runtime."""
from pathlib import Path

def apply(source: Path) -> None:
    dvm = source / "src/translation-layer-next/husk-tl-dvm.c"
    natives = source / "src/translation-layer-next/husk-tl-dvm-natives.c"
    old = """jobj *tl_dvm_string_u16(const uint16_t *s, int32_t n)
{
    jobj *o = tl_jni_new_string("");
    free(o->str.utf8);
    o->str.utf8 = u16_to_utf8(s, n);
    o->str.u16 = malloc((size_t)(n ? n : 1) * 2);
    if (n) memcpy(o->str.u16, s, (size_t)n * 2);
"""
    new = """jobj *tl_dvm_string_u16(const uint16_t *s, int32_t n)
{
    /* Reject invalid spans; a zero-length string may have no backing pointer. */
    if (n < 0 || (n > 0 && !s)) {
        tl_log_line("dvm: rejecting invalid UTF-16 string (length=%d, null=%d)", n, !s);
        return NULL;
    }
    jobj *o = tl_jni_new_string("");
    if (!o) return NULL;
    char *utf8 = u16_to_utf8(n ? s : (const uint16_t *)L"", n);
    uint16_t *copy = malloc((size_t)(n ? n : 1) * sizeof(uint16_t));
    if (!utf8 || !copy) {
        free(utf8);
        free(copy);
        return NULL;
    }
    free(o->str.utf8);
    o->str.utf8 = utf8;
    o->str.u16 = copy;
    if (n) memcpy(o->str.u16, s, (size_t)n * sizeof(uint16_t));
"""
    # Avoid wide-character casts and portability issues: use a local 16-bit sentinel.
    new = new.replace('    char *utf8 = u16_to_utf8(n ? s : (const uint16_t *)L"", n);',
                      '    static const uint16_t empty[1] = {0};\n    char *utf8 = u16_to_utf8(n ? s : empty, n);')
    text = dvm.read_text()
    if text.count(old) != 1: raise RuntimeError("DVM anchor changed")
    dvm.write_text(text.replace(old, new, 1))
    old = """NAT(String_fastSubstring)
{
    int32_t n; const uint16_t *s = chars(self, &n);
    int32_t start = a[0].i, len = a[1].i;
    if (start < 0 || len < 0 || start + len > n) return dvm_throw("java/lang/StringIndexOutOfBoundsException", "substring");
    *ret = L(tl_dvm_string_u16(s + start, len));
    return true;
}
"""
    new = """NAT(String_fastSubstring)
{
    if (!self || !a || !ret) return npe("fastSubstring");
    int32_t n = 0;
    const uint16_t *s = chars(self, &n);
    int32_t start = a[0].i, len = a[1].i;
    /* Subtraction avoids signed overflow in start + len. */
    if (n < 0 || start < 0 || len < 0 || start > n || len > n - start)
        return dvm_throw("java/lang/StringIndexOutOfBoundsException", "substring");
    if (len > 0 && !s) return npe("fastSubstring characters");
    static const uint16_t empty[1] = {0};
    jobj *result = tl_dvm_string_u16(len ? s + start : empty, len);
    if (!result) return dvm_throw("java/lang/OutOfMemoryError", "fastSubstring allocation");
    *ret = L(result);
    return true;
}
"""
    text = natives.read_text()
    if text.count(old) != 1: raise RuntimeError("Native substring anchor changed")
    natives.write_text(text.replace(old, new, 1))

if __name__ == "__main__":
    import sys
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_string_crash.py HUSK_SOURCE")
    apply(Path(sys.argv[1]))
