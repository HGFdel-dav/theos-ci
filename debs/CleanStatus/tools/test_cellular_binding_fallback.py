#!/usr/bin/env python3
"""Actual cellular call expressions + controlled source contracts; never UIKit/radio execution."""
from pathlib import Path
import hashlib,json,re,subprocess,tempfile,sys
ROOT=Path(__file__).resolve().parents[1]
HOOK=ROOT/'Cellular/LCSCellularHooks.m'
POLICY=ROOT/'Cellular/LCSCellularEntryPolicy.h'
FREEZE=ROOT/'docs/BASELINE-0315-ENTRY-BINDING-FALLBACK.json'

def body(text,anchor):
    start=text.index(anchor);op=text.index('{',start);depth=0
    for i in range(op,len(text)):
        if text[i]=='{':depth+=1
        elif text[i]=='}':
            depth-=1
            if not depth:return text[op+1:i]
    raise AssertionError('Unbalanced production body: '+anchor)

def translate(text):
    repl={
      '[self.controller isKindOfClass:LCSNativeCellularClass]':'E->nativeClass',
      '[self.button isDescendantOfView:self.controller.view]':'E->descendant',
      'objc_getAssociatedObject(self.button,&LCSCellularButtonKey)==self':'E->owner',
      'self.button.window==self.boundWindow':'E->boundWindow',
      'self.button.window==self.controller.view.window':'E->controllerWindow',
      'self.button.window!=self.boundWindow':'!E->boundWindow',
      'self.button.window!=self.controller.view.window':'!E->controllerWindow',
      'self.controller.isViewLoaded':'E->loaded',
      'self.controller.isBeingDismissed':'E->dismissing',
      'self.controller.isBeingPresented':'E->presenting',
      'self.controller':'E->controller','self.button.window':'E->attached',
      'self.directPress':'E->directPress','self.windowPress':'E->windowPress',
      'self.appeared':'E->appeared','self.button':'E->button',
      'state.directPress':'E->directPress','state.windowPress':'E->windowPress',
      'state.button':'E->button','[self entryReady]':'HostEntryReady()',
      '[state entryReady]':'HostEntryReady()',
      'LCSExpansionForState(self)':'(LCSCellularExpansion)E->expansion',
      'LCSPresentedSIM':'E->panel','LCSCellularForeground':'E->foreground',
      'gesture.state':'E->phase','top.isBeingDismissed':'E->topDismissing',
      'top.isBeingPresented':'E->topPresenting','!top':'!E->top',
      'BOOL ':'bool ','NSString *reason=nil':'const char *reason=NULL',
      'return;':'return false;','YES':'true','NO':'false','@"':'"'
    }
    for a,b in sorted(repl.items(),key=lambda p:-len(p[0])):text=text.replace(a,b)
    assert not re.search(r'\b(self|state|top)\.',text),text
    assert '[' not in text and '@' not in text,text
    return text

def extract_host(hook):
    live=body(hook,'- (BOOL)entryReady {')
    receive=body(hook,'- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:')
    begin=body(hook,'- (BOOL)shouldBeginPressedGesture:(UIGestureRecognizer *)gesture {')
    press=body(hook,'- (void)pressed:(UILongPressGestureRecognizer *)gesture {')
    receive=receive.replace('LCSCellularButtonState *state=self.binding;','')
    receive=receive.replace('CGPoint point=[touch locationInView:state.button];','')
    receive=receive.replace('CGRectContainsPoint(CGRectInset(state.button.bounds,-8,-10),point)','E->hit')
    receive=receive.replace('[state receivedTouch:gesture];','')
    begin=begin[:begin.index('NSString *reason=')]+ '\nreturn allowed;\n'
    identity=press[:press.index('[self traceGesture:gesture phase:')]
    gates=press[press.index('NSString *reason=nil;'):press.index('    if(reason){')]
    presenter=press[press.index('if(!top||'):press.index('    LCSCellularSIMController *panel=')]
    # Only preserve the actual presenter's condition; log contents have no eligibility effect.
    top_guard=presenter[:presenter.index('{')].strip()
    action=identity+'\nif(gesture.state!=UIGestureRecognizerStateBegan)return false;\n'+gates+'\nif(reason)return false;\n'+top_guard+'return false;\nreturn true;\n'
    out='#include "LCSCellularEntryPolicy.h"\n'
    for name,signature,text in [('HostEntryReady','void',live),('HostReceive','uintptr_t gesture',receive),('HostBegin','uintptr_t gesture',begin),('HostAction','uintptr_t gesture',action)]:
        out+='static bool '+name+'('+signature+'){\n'+translate(text)+'\n}\n'
    return out

def source_checks(hook):
    need=[]
    def check(v,s):
        if not v:raise AssertionError(s)
        need.append(s)
    registration=body(hook,'- (NSString *)bindingFailureForButton:')
    bind=body(hook,'- (void)bindAfterLayout {')
    sync=body(hook,'- (void)syncWindowPress {')
    schedule=body(hook,'- (void)scheduleLayoutRebind {')
    entry=body(hook,'- (BOOL)entryReady {')
    moved=body(hook,'static void LCSRoundDidMoveToWindow(')
    check('LCSVisible' not in registration,'passive preparation must not wait for visibility')
    check('if(!button.window' not in registration,'windowless native button may be prepared')
    check('button.window&&button.window!=self.controller.view.window' in registration,'different live window rejected')
    for key in ['LCSTapContract(button)','button-owned-elsewhere','button-outside-controller','controller-mismatch','device-locked','foreground-inactive']:
        check(key in registration,'passive preparation retains '+key)
    check('[self bindAfterLayout]' in body(hook,'- (void)bind {'),'load binding is not dependent on a later expanded callback')
    check('[self syncWindowPress]' in bind,'binding updates fallback even when direct object is unchanged')
    check('if(button!=self.button||!self.directPress||self.directPress.view!=button)' in bind,'unchanged native recognizer is not replaced')
    check(bind.index('objc_setAssociatedObject(button,')<bind.index('[button addGestureRecognizer:'),'ownership is registered before the recognizer can be queried')
    check(hook.count('self.directPress=[[UILongPressGestureRecognizer alloc]')==1,'one direct allocation site')
    check(hook.count('self.windowPress=[[UILongPressGestureRecognizer alloc]')==1,'one fallback allocation site')
    check('if(!window||self.windowPress)return;' in sync,'window sync is idempotent and never binds nil window')
    check('[self.windowPress.view removeGestureRecognizer:self.windowPress]' in sync,'old fallback is detached from its actual old window')
    check('if(!direct)' not in sync,'fallback preparation is independent of fluctuating ancestor interaction')
    check('cancelsTouchesInView=NO' in sync,'window fallback preserves view touches')
    check('remaining=.25-' in schedule and 'if(self.layoutPending)return;' in schedule and 'remaining*NSEC_PER_SEC' in schedule,'throttled layout checks retain a coalesced trailing callback')
    check(moved.count('LCSOriginalRoundDidMoveToWindow(self,sel)')==1,'window lifecycle original runs once')
    check('state&&state.button==self' in moved,'foreign buttons never get a binding')
    check(moved.index('LCSOriginalRoundDidMoveToWindow(')<moved.index('objc_getAssociatedObject('),'original window lifecycle precedes reconciliation')
    check('"didMoveToWindow",@encode(void),0,NULL' in hook,'scoped window callback ABI is checked')
    check('LCSVisible(self.button)' in entry and 'self.button.window' in entry,'prepared hidden button still cannot start')
    check('entry-outcome' in body(hook,'- (void)receivedTouch:(UIGestureRecognizer *)gesture {') and 'late-%@-%@' in hook,'attempt outcome has a separate diagnostic slot')
    check('route-window' in hook and 'route-direct' in hook,'presenting route can be identified')
    return need

def verify_freeze():
    m=json.loads(FREEZE.read_text());assert len(m['files'])==160 and m['base_version']=='0.3.14'
    allowed=set(m['allowed_changes']);changed=[];extras=[]
    production={n for n in allowed if Path(n).suffix in {'.m','.mm','.xm','.h'} and not n.startswith('tests/')}
    assert production=={'Cellular/LCSCellularHooks.m'},'Only the cellular binding/entry production file is approved'
    assert len(m.get('protected_methods',{}))==6,'Original pan/expanded/preview methods must remain pinned'
    for name,want in m['files'].items():
        path=ROOT/name
        assert path.is_file(),'Missing baseline file '+name
        if hashlib.sha256(path.read_bytes()).hexdigest()!=want:changed.append(name)
    for p in ROOT.rglob('*'):
        if not p.is_file() or any(k in p.parts for k in ['__pycache__','.git','.theos','packages','out']):continue
        name=p.relative_to(ROOT).as_posix()
        if name not in m['files']:extras.append(name)
    assert not (set(changed)|set(extras))-allowed,'Outside declared scope: '+str((set(changed)|set(extras))-allowed)
    for anchor,want in m.get('protected_methods',{}).items():
        assert hashlib.sha256(body(HOOK.read_text(),anchor).encode()).hexdigest()==want,'Protected method changed: '+anchor
    return {'changed':sorted(changed),'new':sorted(extras),'baseline_files':160}

def main():
    hook=HOOK.read_text();contracts=source_checks(hook)
    frozen=verify_freeze();generated=extract_host(hook)
    result={'mode':'Alpine/macOS host C, actual production call expressions with independent UIKit inputs; no UIKit runtime',
      'hook_sha256':hashlib.sha256(HOOK.read_bytes()).hexdigest(),
      'generated_sha256':hashlib.sha256(generated.encode()).hexdigest(),
      'contracts':contracts,'freeze':frozen,'mutants':[]}
    with tempfile.TemporaryDirectory(prefix='lcs315-callchain-') as temp:
        d=Path(temp);header=d/'production_binding_fallback.h';exe=d/'cases'
        def execute(value):
            header.write_text(value)
            build=subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-I'+str(d),'-I'+str(ROOT/'Cellular'),str(ROOT/'tests/cellular/binding_fallback_host.c'),'-o',str(exe)],capture_output=True,text=True)
            assert build.returncode==0,'Host translation must compile: '+build.stderr
            return subprocess.run([str(exe)],capture_output=True,text=True)
        run=execute(generated);assert run.returncode==0,run.stdout+run.stderr
        result['host_stdout']=run.stdout;print(run.stdout.strip())
        mutations=[
          ('receive-double-negation','LCSCellularWindowFallbackAllows(true,LCSDirectTouch(E->button),true,','LCSCellularWindowFallbackAllows(true,!LCSDirectTouch(E->button),true,'),
          ('begin-double-negation','LCSCellularWindowFallbackAllows(true,LCSDirectTouch(E->button),LCSVisible(E->button),local)','LCSCellularWindowFallbackAllows(true,!LCSDirectTouch(E->button),LCSVisible(E->button),local)'),
          ('action-wrong-route','else if(fallback&&LCSDirectTouch(E->button))','else if(fallback&&!LCSDirectTouch(E->button))'),
          ('missing-live-visibility','E->controllerWindow&&LCSVisible(E->button)&&','E->controllerWindow&&true&&')
        ]
        for label,old,new in mutations:
            assert generated.count(old)==1,'Mutation must affect one actual expression: '+label
            bad=execute(generated.replace(old,new));assert bad.returncode!=0,'Actual pipeline must reject '+label
            result['mutants'].append({'name':label,'compiled':True,'exit':bad.returncode,'diagnostic':bad.stderr[:240]})
    if '--report' in sys.argv:
        path=Path(sys.argv[sys.argv.index('--report')+1]);path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
        path.with_suffix('.production.h').write_text(generated)
    print('PASS binding/fallback source contracts:',len(contracts),'; 4 compiled real-call mutations rejected; UIKit/native interaction NOT run.')
if __name__=='__main__':main()
