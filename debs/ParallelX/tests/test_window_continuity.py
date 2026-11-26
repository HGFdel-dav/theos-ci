import pathlib,subprocess,tempfile,unittest,shutil
ROOT=pathlib.Path(__file__).resolve().parents[1]

class WindowContinuity(unittest.TestCase):
    def run_case(self,old=None,new=None):
        with tempfile.TemporaryDirectory(prefix='px-continuity-') as t:
            p=pathlib.Path(t);(p/'Common').mkdir();(p/'tests').mkdir()
            for name in ['PXWindowMemoryPolicy.h','PXWindowContinuity.h']:
                text=(ROOT/'Common'/name).read_text()
                if old and old in text:
                    self.assertEqual(text.count(old),1)
                    text=text.replace(old,new)
                (p/'Common'/name).write_text(text)
            shutil.copyfile(ROOT/'tests/window_continuity_harness.c',p/'tests/harness.c')
            r=subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror',
                *(['-Wno-unused-parameter'] if old else []),str(p/'tests/harness.c'),'-lm','-o',str(p/'run')],capture_output=True,text=True,timeout=45)
            self.assertEqual(r.returncode,0,r.stderr)
            return subprocess.run([str(p/'run')],capture_output=True,text=True,timeout=10)
    def test_real_taobao_geometry_and_lifecycle(self):
        r=self.run_case();self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('WINDOW_CONTINUITY_PASS',r.stdout)
        self.assertGreater(int(r.stdout.split('checks=')[1]),1700)
    def test_compiled_unsafe_variants_are_rejected(self):
        mutants=[
            ('*out=merged.frame;','*out=requested.frame;'),
            ('targetEpoch==currentEpoch &&','true &&'),
            ('targetGeneration==currentGeneration &&','true &&'),
            ('bound && identityMatches && enabled','bound && enabled'),
            ('!transient && directionMatches && referenceMatches','directionMatches && referenceMatches'),
            ('sameGeometryAttempts < 2 && generationAttempts < 4','sameGeometryAttempts < 2'),
            ('sameGeometryAttempts < 2 && generationAttempts < 4','generationAttempts < 4'),
            ('double s=fmin(canvas.width/sourceW,canvas.height/sourceH);','double s=1.0;'),
            ('fabs(a.x-b.x)<=tolerance && fabs(a.y-b.y)<=tolerance &&','true &&'),
        ]
        for old,new in mutants:
            with self.subTest(mutation=old):
                text=(ROOT/'Common/PXWindowContinuity.h').read_text()
                self.assertEqual(text.count(old),1)
                r=self.run_case(old,new)
                self.assertNotEqual(r.returncode,0,'compiled unsafe variant passed')
    def test_real_adapter_uses_policy_and_content_coordinate_space(self):
        s=(ROOT/'Common/PXWindowMemory.m').read_text()
        self.assertIn('PXWMKeepMoveSize(context.continuityGeometry,moving,&target)',s)
        self.assertIn('[host convertRect:host.bounds toView:canvas]',s)
        self.assertIn('PXWMContentFit(PXWMFromRect(canvas.bounds)',s)
        self.assertIn('current.generation!=generation',s)
        self.assertIn('current.continuityScheduleGeneration==generation',s)
        self.assertIn('PXWMProbeContentGeometry(context,3)',s)
        probe=s.split('static void PXWMProbeContentGeometry(PXWMContext *context, unsigned stage) {',1)[1].split('/* Sample a live window',1)[0]
        for field in ['@"probeSchema":@3','@"measured"','@"cardX"','@"shownX"','@"positionMismatch"','@"ta"','@"tb"','@"tc"','@"td"','@"tx"','@"ty"','@"canvasMatch"']:
            self.assertIn(field,probe)
        for forbidden in ['PXWMQueueContentSync(','.frame =','.transform =','PXWMOriginalLayout(']:
            self.assertNotIn(forbidden,probe)

if __name__=='__main__':unittest.main(verbosity=2)
