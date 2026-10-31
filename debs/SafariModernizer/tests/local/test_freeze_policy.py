import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
HEADER = ROOT / 'tweak' / 'SMFreezePolicy.h'


class FreezePolicyTests(unittest.TestCase):
    def test_compiled_stage_and_escalation_policy(self):
        source = r'''#include <assert.h>
#include "SMFreezePolicy.h"
int main(void) {
    assert(SMFreezeStageNeedsModuleOff("module rewrite abs.twimg.com/app.js"));
    assert(SMFreezeStageNeedsModuleOff("module scan abs.twimg.com/app.js"));
    assert(!SMFreezeStageNeedsModuleOff("script abs.twimg.com/app.js"));
    assert(!SMFreezeStageNeedsModuleOff("CSS rewrite site.css"));
    assert(!SMFreezeStageNeedsModuleOff(0));
    assert(SMFreezeNextLevel(0, 1, 1) == 2);
    assert(SMFreezeNextLevel(1, 1, 1) == 2);
    assert(SMFreezeNextLevel(2, 1, 1) == 3);
    assert(SMFreezeNextLevel(0, 1, 0) == 1);
    assert(SMFreezeNextLevel(1, 1, 0) == 2);
    assert(SMFreezeNextLevel(2, 1, 0) == 3);
    assert(SMFreezeNextLevel(0, 0, 1) == 0);
    assert(SMFreezeNextLevel(3, 1, 1) == 3);
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as temp:
            c_file = pathlib.Path(temp) / 'test.c'
            binary = pathlib.Path(temp) / 'test'
            c_file.write_text(source)
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-I', str(HEADER.parent), str(c_file), '-o', str(binary)],
                           check=True, capture_output=True, text=True)
            subprocess.run([str(binary)], check=True, capture_output=True, text=True)

    def test_runtime_uses_same_module_predicate_and_skips_loader_at_level_two(self):
        tweak = (ROOT / 'tweak' / 'Tweak.x').read_text()
        main = (ROOT / 'web' / 'main.js').read_text()
        self.assertIn('SMFreezeStageNeedsModuleOff(st.UTF8String)', tweak)
        self.assertIn('SMFreezeNextLevel((int)level, (int)tweakStep, (int)moduleStep)', tweak)
        self.assertIn('if (level < 2) { try { startModuleLoader', main)


if __name__ == '__main__':
    unittest.main()
