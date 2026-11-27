import importlib.util,unittest
from pathlib import Path
P=Path(__file__).resolve().parents[1]/'tools/read_window_diagnostics.py'
spec=importlib.util.spec_from_file_location('window_reader',P);r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)
class WindowDiagnosticReader(unittest.TestCase):
 def event(self,pid=1,session='a',serial=19):
  return {'event':'content_geometry_probe','pid':pid,'build':'clone-test','session':session,'time':1,'sequence':1,'state':{'appHash':5,'openSerial':serial,'scale':1,'clip':1,'scaleMismatch':1}}
 def test_join_includes_process_session_not_only_serial(self):
  a=self.event();b=self.event(pid=2);c=self.event(session='b')
  self.assertEqual(len(r.summarize([a,b,c])['groups']),3)
 def test_legacy_scale_cannot_be_interpreted_as_display_failure(self):
  e=r.describe(self.event());self.assertIn('not_display_scale',e['interpretation'])
  e=self.event();e['state'].update(probeSchema=3,measured=False)
  self.assertIn('unmeasured',r.describe(e)['interpretation'])
 def test_incident_preserves_evicted_events_and_only_content_recovered(self):
  a=self.event();a['event']='continuity_decision';a['state'].update(reason=22,lane=3)
  b=self.event();b.update(sequence=2,time=2,event='restore_postlayout_geometry_verified')
  x=r.summarize([b],{'schema':1,'incidents':[{'trigger':a,'before':[],'after':[b]}]})
  self.assertEqual(len(x['groups'][0]['events']),2)
  self.assertEqual(x['groups'][0]['events'][0]['reasonName'],'budget_exhausted')
  self.assertFalse(x['incidents'][0]['contentRecovered'])
 def test_host_dispatch_never_claims_remote_input_processed(self):
  e=self.event();e['event']='input_host_dispatch';e['state'].update(inputSchema=1,launchToken=0,phaseMask=10,receiverMask=2,dispatchReturned=True)
  x=r.describe(e)
  self.assertEqual(x['phases'],['moved','ended']);self.assertEqual(x['receivers'],['hosted_app_view'])
  self.assertTrue(x['ordinaryNativeOpen']);self.assertEqual(x['remoteReceipt'],'not_measured')
  self.assertEqual(x['applicationResponsiveness'],'not_measured')
if __name__=='__main__':unittest.main(verbosity=2)
