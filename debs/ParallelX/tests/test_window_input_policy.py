from pathlib import Path
import tempfile,subprocess,unittest,shutil
ROOT=Path(__file__).resolve().parents[1]
class InputPolicy(unittest.TestCase):
 def exercise(self,old=None,new=None):
  with tempfile.TemporaryDirectory() as t:
   p=Path(t);(p/'Common').mkdir();(p/'tests').mkdir()
   h=(ROOT/'Common/PXWindowInputPolicy.h').read_text()
   if old:self.assertEqual(h.count(old),1);h=h.replace(old,new)
   (p/'Common/PXWindowInputPolicy.h').write_text(h)
   shutil.copyfile(ROOT/'tests/window_input_policy_harness.c',p/'tests/test.c')
   args=['cc','-std=c11','-Wall','-Wextra','-Werror']+(['-Wno-unused-parameter'] if old else [])
   b=subprocess.run(args+[str(p/'tests/test.c'),'-lm','-o',str(p/'run')],capture_output=True,text=True,timeout=40)
   self.assertEqual(b.returncode,0,b.stderr)
   return subprocess.run([str(p/'run')],capture_output=True,text=True,timeout=10)
 def test_real_policy(self):
  r=self.exercise();self.assertEqual(r.returncode,0,r.stderr);self.assertIn('INPUT_POLICY_PASS',r.stdout)
 def test_compiled_policy_faults_rejected(self):
  for a,b in [('r->used>=8','r->used>=999'),('!r->initialized','!r->start'),
    ('registered && exactWindow && exactCanvas && exactBundle && observedSerial &&','registered && exactWindow && exactCanvas && observedSerial &&'),
    ('observedSerial==currentSerial','true'),('return registered && scheduled && scheduled==current;','return scheduled && scheduled==current;'),
    ('end>=start ?','true ?')]:
   with self.subTest(mutation=a):self.assertNotEqual(self.exercise(a,b).returncode,0)
 def test_observer_forwards_original_without_input_or_layout_mutation(self):
  s=(ROOT/'Common/PXWindowInputDiagnostics.m').read_text()
  for forbidden in ['locationInView:', 'hitTest:', 'touchesBegan:', 'setUserInteractionEnabled:', '.frame=', '.transform=', 'setAllowsSelection:', 'activateApplication:', 'kill(']:
   self.assertNotIn(forbidden,s)
  for required in ['touch.view','PXInputOriginalSendEvent(self,command,event)','@finally','input_host_arrived','input_host_dispatch',
                   'state[@"remoteReceiptKnown"]=@NO','state[@"appResponsivenessKnown"]=@NO','state[@"hostPhaseKnown"]=@NO']:
   self.assertIn(required,s)
  self.assertEqual(s.count('PXInputOriginalSendEvent(self,command,event)'),1)
  self.assertIn('PXInputTarget(bundle)',s)
if __name__=='__main__':unittest.main(verbosity=2)
