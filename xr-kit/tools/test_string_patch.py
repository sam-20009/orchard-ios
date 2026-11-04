#!/usr/bin/env python3
"""Regression checks for Samuel VR Box's pinned Husk string crash workaround."""
import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from patch_string_crash import apply

DVM_ANCHOR = '''jobj *tl_dvm_string_u16(const uint16_t *s, int32_t n)
{
    jobj *o = tl_jni_new_string("");
    free(o->str.utf8);
    o->str.utf8 = u16_to_utf8(s, n);
    o->str.u16 = malloc((size_t)(n ? n : 1) * 2);
    if (n) memcpy(o->str.u16, s, (size_t)n * 2);
'''
SUBSTRING_ANCHOR = '''NAT(String_fastSubstring)
{
    int32_t n; const uint16_t *s = chars(self, &n);
    int32_t start = a[0].i, len = a[1].i;
    if (start < 0 || len < 0 || start + len > n) return dvm_throw("java/lang/StringIndexOutOfBoundsException", "substring");
    *ret = L(tl_dvm_string_u16(s + start, len));
    return true;
}
'''

class NativeStringPatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        folder = self.root / 'src/translation-layer-next'
        folder.mkdir(parents=True)
        (folder / 'husk-tl-dvm.c').write_text(DVM_ANCHOR)
        (folder / 'husk-tl-dvm-natives.c').write_text(SUBSTRING_ANCHOR)

    def tearDown(self):
        self.temp.cleanup()

    def test_patch_uses_safe_bounds_and_zero_length_sentinel(self):
        apply(self.root)
        dvm = (self.root / 'src/translation-layer-next/husk-tl-dvm.c').read_text()
        native = (self.root / 'src/translation-layer-next/husk-tl-dvm-natives.c').read_text()
        self.assertIn('n > 0 && !s', dvm)
        self.assertIn('static const uint16_t empty[1] = {0}', dvm)
        self.assertIn('len > n - start', native)
        self.assertIn('len > 0 && !s', native)
        self.assertIn('len ? s + start : empty', native)
        self.assertNotIn('start + len > n', native)
        self.assertNotIn('L""', dvm)

    def test_changed_source_fails_closed(self):
        p = self.root / 'src/translation-layer-next/husk-tl-dvm.c'
        p.write_text('upstream changed')
        with self.assertRaises(RuntimeError):
            apply(self.root)

if __name__ == '__main__':
    unittest.main()
