"""Focused host Objective-C syntax gate for the actual context/helper.

No Foundation/UIKit or iOS target is used, and no object/binary is emitted.
This catches property-versus-ivar errors; it does NOT replace the complete
Apple SDK build or any UIKit/device acceptance check.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Common/PXWindowMemory.m'


def actual_parts():
    source = SOURCE.read_text()
    start = source.index('@interface PXWMContext : NSObject {')
    end = source.index('@end', start) + len('@end')
    interface = source[start:end]
    start = source.index('@implementation PXWMContext\n')
    end = source.index('@end', start) + len('@end')
    implementation = source[start:end]
    start = source.index('static BOOL PXWMInitialFrameMayPrepare(PXWMContext *context) {')
    depth = 0
    for end in range(source.index('{', start), len(source)):
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
            if depth == 0:
                return interface, implementation, source[start:end + 1]
    raise AssertionError('unterminated actual first-frame helper')


class WindowMemoryContextPropertySyntax(unittest.TestCase):
    def compile_actual(self, helper=None):
        compiler = shutil.which('clang')
        self.assertIsNotNone(compiler, 'clang is required: this syntax gate must not silently skip')
        interface, implementation, actual_helper = actual_parts()
        if helper is None:
            helper = actual_helper
        # Keep the COMPLETE production context declaration/implementation and
        # production C lifecycle header. Only unrelated framework class/type
        # declarations are shimmed for a host-only syntax translation unit.
        prefix = '''#include "Common/PXWindowMemoryPolicy.h"
typedef signed char BOOL;
typedef unsigned long NSUInteger;
typedef double CFTimeInterval;
__attribute__((objc_root_class))
@interface NSObject
@end
@class UIView, NSString, PXWMGesture;
'''
        unit = '\n'.join((prefix, interface, implementation, helper,
                          'BOOL PXWMContextPropertyProbe(PXWMContext *context) {\n'
                          '    return PXWMInitialFrameMayPrepare(context);\n}\n'))
        with tempfile.TemporaryDirectory(prefix='pxwm-property-syntax-') as temp:
            path = Path(temp) / 'actual_context.m'
            path.write_text(unit)
            runtime = 'macosx-10.13' if sys.platform == 'darwin' else 'gnustep-2.0'
            command = [compiler, '-x', 'objective-c', '-std=gnu11',
                       '-fsyntax-only', '-fobjc-arc', '-fobjc-runtime=' + runtime,
                       '-Wall', '-Wextra', '-Werror', '-I', str(ROOT), str(path)]
            result = subprocess.run(command, text=True, capture_output=True, timeout=30)
            # The compiler is explicitly syntax-only; assert no object is left.
            self.assertEqual(sorted(p.name for p in Path(temp).iterdir()), ['actual_context.m'])
            return result

    def test_actual_context_and_first_frame_helper_compile(self):
        result = self.compile_actual()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_previous_arrow_property_regression_is_compiler_rejected(self):
        helper = actual_parts()[2]
        self.assertEqual(helper.count('context.generation'), 1)
        broken = helper.replace('context.generation', 'context->generation')
        result = self.compile_actual(broken)
        self.assertNotEqual(result.returncode, 0, 'the old CI failure unexpectedly passed')
        self.assertIn('generation', result.stderr)
        self.assertRegex(result.stderr, r'(no member|does not have a member)')

    def test_direct_synthesized_private_ivar_is_compiler_rejected(self):
        helper = actual_parts()[2]
        self.assertEqual(helper.count('context.generation'), 1)
        result = self.compile_actual(helper.replace('context.generation', 'context->_generation'))
        self.assertNotEqual(result.returncode, 0, 'private synthesized ivar unexpectedly passed')
        self.assertRegex(result.stderr, r"_generation.*private")

    def test_context_properties_are_not_read_as_public_struct_fields(self):
        interface, _, helper = actual_parts()
        properties = re.findall(r'@property\([^)]*\)[^;]*?\b(\w+)\s*;', interface)
        self.assertIn('generation', properties)
        source = SOURCE.read_text()
        for name in properties:
            with self.subTest(property=name):
                self.assertNotRegex(source, r'\bcontext\s*->\s*' + re.escape(name) + r'\b')
        # native really is the explicitly public C lifecycle ivar, not a property.
        self.assertIn('@public\n    PXWMNativeLifecycle native;', interface)
        self.assertIn('context->native.serial', helper)
        self.assertIn('(uint64_t)context.generation', helper)


if __name__ == '__main__':
    unittest.main(verbosity=2)
