#!/usr/bin/env python3
"""Read ONLY local exported diagnostics; never connect to or modify a device."""
import argparse,json,plistlib
from pathlib import Path
REASONS=['none','inactive','restoring','binding','geometry','disabled','epoch','generation',
 'identity','direction','reference','transient','queued','syncing','no_layout','resize',
 'no_host','host_tree','no_source_method','source_exception','source_size','converted_rect',
 'budget_exhausted','changed_target','no_card','cancelled','save_pending','not_measured','diagnostic_limit','interacting']
LANES=['arm','ready','content_measurement','queue','callback','frame_reconcile','first_frame']
def load(path):
 raw=Path(path).read_bytes()
 if len(raw)>2*1024*1024:raise ValueError('export exceeds 2 MiB')
 return json.loads(raw) if raw.lstrip().startswith((b'{',b'[')) else plistlib.loads(raw)
def key(event):
 s=event.get('state',{})
 return (str(event.get('session','legacy-no-session')),str(event.get('build','?')),
         str(event.get('pid','?')),str(s.get('appHash','?')),str(s.get('openSerial','?')))
def describe(event):
 e=dict(event);s=e.get('state',{})
 if e.get('event')=='continuity_decision':
  r=s.get('reason');l=s.get('lane')
  e['reasonName']=REASONS[r] if isinstance(r,int) and 0<=r<len(REASONS) else 'unknown'
  e['laneName']=LANES[l] if isinstance(l,int) and 0<=l<len(LANES) else 'unknown'
 if e.get('event')=='content_geometry_probe':
  if s.get('probeSchema',1)<2:
   e['interpretation']='legacy_bounds_ratio_not_display_scale; clip/scaleMismatch alone are not failure evidence'
  elif not s.get('measured',False):e['interpretation']='unmeasured; no successful display geometry conclusion'
  else:e['interpretation']='converted_content_rectangle; model evidence, not pixel/video proof'
 if s.get('inputSchema'):
  e['interpretation']='host_side_observation_only; no remote receipt or app responsiveness proof'
  phases=['began','moved','stationary','ended','cancelled']; receivers=['none','hosted_app_view','canvas_other','keyboard_overlay','window_other']
  e['phases']=[name for bit,name in enumerate(phases) if int(s.get('phaseMask',0)) & (1<<bit)]
  e['receivers']=[name for bit,name in enumerate(receivers) if int(s.get('receiverMask',0)) & (1<<bit)]
  e['ordinaryNativeOpen']=s.get('launchToken')==0
  e['remoteReceipt']='not_measured';e['applicationResponsiveness']='not_measured'
 if e.get('event')=='first_frame_boundary':
  e['boundaryPath']={1:'bind',2:'prepare',3:'settle'}.get(s.get('path'),'unknown')
  e['boundaryPhase']={0:'before',1:'after'}.get(s.get('phase'),'unknown')
 return e
def summarize(recent,archive=None):
 if not isinstance(recent,list):raise ValueError('recent export must be an event array')
 archive=archive or {'schema':1,'incidents':[]}
 if not isinstance(archive,dict) or archive.get('schema')!=1:raise ValueError('unsupported archive schema')
 groups={};seen=set()
 def add(e,source):
  if not isinstance(e,dict) or not isinstance(e.get('state'),dict):raise ValueError('invalid event')
  k=key(e);identity=(k,e.get('sequence'),e.get('time'),e.get('event'))
  if identity in seen:return
  seen.add(identity);groups.setdefault(k,[]).append(dict(describe(e),evidenceSource=source))
 for e in recent:add(e,'recent')
 incidents=[]
 for item in archive.get('incidents',[]):
  for slot in ('before','after'):
   for e in item[slot]:add(e,'incident_'+slot)
  add(item['trigger'],'incident_trigger')
  if item.get('lastOutcome'):add(item['lastOutcome'],'incident_outcome')
  incidents.append({'window':key(item['trigger']),'triggerTime':item['trigger'].get('time'),
   'beforeCount':len(item['before']),'afterCount':len(item['after']),
   'kind':'input_observation' if item['trigger'].get('state',{}).get('inputSchema') else 'geometry',
   'contentRecovered':bool(item.get('recovered',False)),'closed':bool(item.get('closed',False))})
 result=[]
 for k,events in groups.items():
  events.sort(key=lambda e:(e.get('time',0),e.get('sequence',0)))
  result.append({'session':k[0],'build':k[1],'pid':k[2],'appHash':k[3],'openSerial':k[4],'events':events})
 return {'schema':1,'groups':result,'incidents':incidents,
  'limits':'recent<=256; incidents<=4; each before<=12 after<=12 plus trigger/outcome; after<=120s; missing events are unknown'}
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--recent',required=True);p.add_argument('--incidents');args=p.parse_args()
 print(json.dumps(summarize(load(args.recent),load(args.incidents) if args.incidents else None),ensure_ascii=False,indent=2))
if __name__=='__main__':main()
