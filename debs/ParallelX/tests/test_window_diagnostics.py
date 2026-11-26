from pathlib import Path
import os,subprocess,tempfile,unittest,shutil,sys
ROOT=Path(__file__).resolve().parents[1]
CASES=['history','rollover','corrupt','symlink','fifo']+['fault'+str(i) for i in range(1,8)]
class WindowDiagnostics(unittest.TestCase):
 def portable(self,mutation=None):
  with tempfile.TemporaryDirectory(prefix='px-diagnostic-') as t:
   p=Path(t);(p/'Common').mkdir();(p/'tests').mkdir()
   s=(ROOT/'Common/PXWindowDiagnosticPolicy.h').read_text()
   if mutation:
    old,new=mutation;self.assertEqual(s.count(old),1);s=s.replace(old,new)
   (p/'Common/PXWindowDiagnosticPolicy.h').write_text(s)
   shutil.copyfile(ROOT/'tests/window_diagnostic_policy_harness.c',p/'tests/test.c')
   build=subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror',str(p/'tests/test.c'),'-lm','-o',str(p/'run')],capture_output=True,text=True)
   self.assertEqual(build.returncode,0,build.stderr)
   return subprocess.run([str(p/'run')],capture_output=True,text=True)
 def test_actual_policy(self):
  r=self.portable();self.assertEqual(r.returncode,0,r.stderr);self.assertIn('DIAGNOSTIC_POLICY_PASS',r.stdout)
 def test_compiled_diagnostic_mutations_rejected(self):
  for m in [('(gate->seen[lane]&bit) ||','false ||'),('gate->count>=PXWMDiagnosticReasonLimit','false'),
            ('count<PXWMDiagnosticAfterLimit','count<999'),('now-started<=120','now-started<=999')]:
   with self.subTest(m=m):self.assertNotEqual(self.portable(m).returncode,0)
 def test_full_diagnostics_ios155_syntax(self):
  if sys.platform=='darwin':self.skipTest('Apple lane executes real Foundation below')
  clang=shutil.which('clang');sdk=Path('/opt/theos/sdks/iPhoneOS15.5.sdk');self.assertTrue(clang and sdk.exists())
  r=subprocess.run([clang,'-fsyntax-only','-target','arm64e-apple-ios15.0','-isysroot',str(sdk),'-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-I'+str(ROOT),str(ROOT/'tests/window_diagnostics_host.m'),str(ROOT/'Common/PXWindowMemoryStore.m')],capture_output=True,text=True,timeout=60)
  self.assertEqual(r.returncode,0,r.stderr)
 def test_real_foundation_diagnostic_storage(self):
  if sys.platform!='darwin' or not shutil.which('xcrun'):
   if os.environ.get('PXWM_REQUIRE_NATIVE')=='1' or sys.platform=='darwin':self.fail('native diagnostic storage REQUIRED: missing macOS/xcrun')
   self.skipTest('Apple diagnostic I/O behavior not run; Linux syntax is separate')
  with tempfile.TemporaryDirectory(prefix='px-diagnostics-native-') as t:
   p=Path(t).resolve();exe=p/'run'
   r=subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-framework','Foundation',str(ROOT/'tests/window_diagnostics_host.m'),str(ROOT/'Common/PXWindowMemoryStore.m'),'-o',str(exe)],capture_output=True,text=True,timeout=60)
   self.assertEqual(r.returncode,0,r.stderr)
   for case in CASES:
    with self.subTest(case=case):
     root=p/case/'Containers/Shared/AppGroup/.jbroot-fixture';root.mkdir(parents=True)
     r=subprocess.run([str(exe),case],env={**os.environ,'PXWM_TEST_ROOT':str(root)},capture_output=True,text=True,timeout=45)
     self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertIn('PASS '+case,r.stdout)
if __name__=='__main__':unittest.main(verbosity=2)
