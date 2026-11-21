#!/usr/bin/env python3
"""Strict RootHide artifact checks; not AMFI acceptance or runtime validation."""
import hashlib, json, os, plistlib, struct, subprocess, sys, tempfile
from pathlib import Path
from panel_routes import validate_panel_routes
from der_entitlements import decode_der_entitlements

def u32(b,p,end='<'): return struct.unpack_from(end+'I',b,p)[0]
def require(ok,why):
    if not ok: raise ValueError(why)
def version(value): return '.'.join(str((value>>s)&255) for s in (16,8,0))
HELPER_ENTITLEMENTS={'platform-application':True,'com.apple.CommCenter.fine-grained':['cellular-plan','spi','preferences-write']}
def macho(path,expected_entitlements=None):
    b=path.read_bytes()
    require(b[:4]==b'\xcf\xfa\xed\xfe','must be thin Mach-O64')
    require(u32(b,4)==0x100000c,'CPU arm64')
    subtype=u32(b,8)
    require((subtype&0xffffff)==2,'arm64e subtype required')
    ncmds=u32(b,16); command_end=32+u32(b,20); pos=32; sig=None; sdk=None; minimum=None; deps=[]
    for _ in range(ncmds):
        cmd,size=struct.unpack_from('<II',b,pos)
        require(size>=8 and pos+size<=command_end<=len(b),'load command bounds')
        if cmd==0x1d: sig=struct.unpack_from('<II',b,pos+8)
        if cmd==0x32:
            platform,minimum,sdk=struct.unpack_from('<III',b,pos+8)
            require(platform==2,'platform iOS')
        if cmd==0x25: minimum,sdk=struct.unpack_from('<II',b,pos+8)
        if cmd in (0xc,0x80000018,0x8000001f):
            off=u32(b,pos+8); require(0<off<size,'dylib name bounds')
            dep=b[pos+off:pos+size].split(b'\0')[0].decode()
            require(not dep.startswith('/Users/') and '/var/jb/' not in dep,'unacceptable runtime dependency '+dep)
            deps.append(dep)
        pos+=size
    require(pos==command_end,'load command count/size agree')
    require(sdk==0x0f0500 and minimum==0x0f0500,'SDK and minOS must both be 15.5')
    require(sig is not None,'missing code signature')
    off,size=sig
    require(off+size<=len(b),'signature range')
    blob=b[off:off+size]
    magic,length,count=struct.unpack_from('>III',blob)
    require(magic==0xfade0cc0 and length<=len(blob) and 12+count*8<=length,'superblob bounds')
    directories=[]; entitlements=[]; der_entitlements=[]; entitlement_slots=set()
    for i in range(count):
        slot,at=struct.unpack_from('>II',blob,12+8*i)
        require(at+8<=length,'slot header')
        cm,cl=struct.unpack_from('>II',blob,at)
        require(cl>=8 and at+cl<=length,'slot body')
        if slot in (5,7):
            require(slot not in entitlement_slots,'duplicate entitlement slot')
            entitlement_slots.add(slot)
        if slot==5:
            require(cm==0xfade7171,'entitlement slot magic')
            ent=plistlib.loads(blob[at+8:at+cl]); require(ent==(expected_entitlements or {}),'unexpected entitlements')
            entitlements.append(ent)
        if slot==7:
            require(expected_entitlements is not None and cm==0xfade7172,'DER only permitted for the explicitly entitled helper')
            ent=decode_der_entitlements(blob[at+8:at+cl]); require(ent==expected_entitlements,'unexpected DER entitlement permissions')
            der_entitlements.append(ent)
        if slot!=0 and not 0x1000<=slot<0x2000: continue
        require(cm==0xfade0c02 and cl>=44,'CodeDirectory')
        cd=blob[at:at+cl]
        v,flags,hashoff,ident,nsp,ncode,limit=struct.unpack_from('>7I',cd,8)
        hs,ht,platform,ps=struct.unpack_from('4B',cd,36)
        if v>=0x20300 and limit==0xffffffff: limit=struct.unpack_from('>Q',cd,56)[0]
        hasher={1:hashlib.sha1,2:hashlib.sha256,3:hashlib.sha256,4:hashlib.sha384}.get(ht)
        require(hasher and 0<hs<=hasher().digest_size and ps<=20,'signature hash/page type')
        page=1<<ps if ps else limit
        require(limit<=off and (ncode==(limit+page-1)//page if page else ncode==0),'code range/page count')
        require(hashoff-nsp*hs>=0 and hashoff+ncode*hs<=cl,'hash table bounds')
        for k in range(ncode):
            actual=hasher(b[k*page:min((k+1)*page,limit)]).digest()[:hs]
            require(actual==cd[hashoff+k*hs:hashoff+(k+1)*hs],f'{path.name}: signature code page {k}')
        for special,special_slot in ((5,5),(7,7)):
            if special>nsp:
                require(not any(u32(blob,12+j*8,'>')==special_slot for j in range(count)),'entitlement present but not covered by CodeDirectory')
                continue
            want=cd[hashoff-special*hs:hashoff-(special-1)*hs]
            matching=None
            for j in range(count):
                st,so=struct.unpack_from('>II',blob,12+j*8)
                if st==special_slot:
                    sl=u32(blob,so+4,'>'); matching=blob[so:so+sl]; break
            if matching is not None: require(want==hasher(matching).digest()[:hs],'special slot hash')
            else: require(want==bytes(hs),'missing hashed special slot')
        directories.append({'hash_type':ht,'pages':ncode})
    if expected_entitlements: require(entitlements==[expected_entitlements],'required helper entitlements missing/duplicated')
    if der_entitlements: require(der_entitlements==entitlements==[expected_entitlements],'XML/DER entitlement mismatch')
    require(any(d['hash_type'] in (2,3) for d in directories),'SHA256 directory required')
    return dict(file=path.name,architecture='arm64e',subtype=hex(subtype),sdk=version(sdk),
                minimum_ios=version(minimum),directories=directories,entitlements=entitlements,der_entitlements=der_entitlements,dependencies=deps)

def inspect(deb,out):
    fields={}
    raw=subprocess.check_output(['dpkg-deb','-f',str(deb)],text=True)
    for line in raw.splitlines():
        if line and not line.startswith(' ') and ':' in line:
            key,val=line.split(':',1);fields[key]=val.strip()
    for key,want in {'Package':'com.local.cleanstatus','Version':'0.3.3','Architecture':'iphoneos-arm64e'}.items():
        require(fields.get(key)==want,key+' mismatch')
    report={'deb':deb.name,'sha256':hashlib.sha256(deb.read_bytes()).hexdigest(),'fields':fields}
    with tempfile.TemporaryDirectory(prefix='cleanstatus-deb-') as temp:
        root=Path(temp);payload=root/'payload';control=root/'control'
        subprocess.run(['dpkg-deb','-x',str(deb),str(payload)],check=True)
        subprocess.run(['dpkg-deb','-e',str(deb),str(control)],check=True)
        require(not any(p.name in ('preinst','postinst','prerm','postrm','config','triggers') for p in control.iterdir()),'unexpected maintainer actions')
        files=sorted(p.relative_to(payload).as_posix() for p in payload.rglob('*') if p.is_file())
        helper_path='usr/libexec/LocalCleanStatus/LocalCleanStatusSIMTool'
        require(files and all(x.startswith('Library/') or x==helper_path for x in files),'RootHide payload paths plus exactly one identity-checked helper')
        require(not any('/var/' in '/'+x or any(t in Path(x).parts for t in ('.git','.theos','packages','Sources','Headers','tools','tests')) for x in files),'unwanted payload')
        require(not any(p.is_symlink() for p in payload.rglob('*')),'unexpected payload symlinks')
        dyn=payload/'Library/MobileSubstrate/DynamicLibraries'
        require(plistlib.loads((dyn/'LocalCleanStatus.plist').read_bytes())=={'Filter':{'Bundles':['com.apple.UIKit','com.apple.springboard']}},'injection filter')
        require(plistlib.loads((dyn/'LocalCleanStatusAnimations.plist').read_bytes())=={'Filter':{'Bundles':['com.apple.springboard']}},'animation injection must be SpringBoard only')
        pref=payload/'Library/PreferenceBundles/LocalCleanStatusPrefs.bundle'
        info=plistlib.loads((pref/'Info.plist').read_bytes())
        require(info['CFBundleExecutable']=='LocalCleanStatusPrefs' and info['NSPrincipalClass']=='LocalCleanStatusRootListController','panel linkage')
        require(info['CFBundleVersion']==info['CFBundleShortVersionString']=='0.3.3','panel version')
        require((pref/'LocalCleanStatusRoot.plist').is_file(),'missing specifiers')
        for name in ('LocalCleanStatusAnimations.plist','LocalCleanStatusAnimationsAdvanced.plist'):
            require(isinstance(plistlib.loads((pref/name).read_bytes()).get('items'),list),'missing animation panel '+name)
        for name,size in (('icon.png',29),('icon@2x.png',58),('icon@3x.png',87)):
            raw=(pref/name).read_bytes()
            require(raw.startswith(bytes.fromhex('89504e470d0a1a0a')) and int.from_bytes(raw[16:20],'big')==size and int.from_bytes(raw[20:24],'big')==size,'bad icon '+name)
        loader=payload/'Library/PreferenceLoader/Preferences/LocalCleanStatusPrefs.plist'
        entry=plistlib.loads(loader.read_bytes())['entry']; require(entry['bundle']=='LocalCleanStatusPrefs' and entry['icon']=='icon.png','loader bundle/icon')
        report['static_panel_routes_checked']=validate_panel_routes(pref,loader)
        module=payload/'Library/ControlCenter/Bundles/LocalCleanStatusSystemActions.bundle'
        require((module/'Info.plist').is_file(),'missing CC module plist')
        module_info=plistlib.loads((module/'Info.plist').read_bytes())
        require(module_info.get('NSPrincipalClass')=='LCSCSystemActionsModule','module principal class')
        require(module_info.get('CFBundleExecutable')=='LocalCleanStatusSystemActions','module executable')
        require(module_info.get('CCSModuleSize',{}).get('Portrait',{}).get('Width')==1,'module 1x1')
        require(module_info.get('CFBundleIconFiles')==['SettingsIcon'],'module settings icon declared')
        for name,size in (('SettingsIcon.png',29),('SettingsIcon@2x.png',58),('SettingsIcon@3x.png',87)):
            raw=(module/name).read_bytes()
            require(raw.startswith(bytes.fromhex('89504e470d0a1a0a')) and int.from_bytes(raw[16:20],'big')==size and int.from_bytes(raw[20:24],'big')==size,'bad module settings icon '+name)
        data=payload/'Library/ControlCenter/Bundles/LocalCleanStatusDataSwitch.bundle'
        data_info=plistlib.loads((data/'Info.plist').read_bytes())
        require(data_info.get('NSPrincipalClass')=='LCSDataSwitchModule' and data_info.get('CFBundleExecutable')=='LocalCleanStatusDataSwitch','data module linkage')
        require(data_info.get('CFBundleVersion')==data_info.get('CFBundleShortVersionString')=='0.3.3','data module version')
        require(data_info.get('CCSModuleSize')=={'Portrait':{'Width':1,'Height':1},'Landscape':{'Width':1,'Height':1}},'data module 1x1')
        require(plistlib.loads((dyn/'LocalCleanStatusCellular.plist').read_bytes())=={'Filter':{'Bundles':['com.apple.springboard']}},'cellular injection must be SpringBoard only')
        require((pref/'LocalCleanStatusCellular.plist').is_file(),'cellular panel shipped')
        for directory,stem,base in ((data,'SettingsIcon',29),(data,'DataSwitch',50),(pref,'CellularIcon',29)):
            for scale,suffix in ((1,''),(2,'@2x'),(3,'@3x')):
                raw=(directory/(stem+suffix+'.png')).read_bytes()
                require(raw.startswith(bytes.fromhex('89504e470d0a1a0a')) and struct.unpack('>II',raw[16:24])==(base*scale,base*scale),'cellular icon '+stem+suffix)
        require(sorted(p.name for p in (payload/'Library/ControlCenter/Bundles').iterdir())==['LocalCleanStatusDataSwitch.bundle','LocalCleanStatusSystemActions.bundle'],'exactly one added CC module')
        binaries=[dyn/'LocalCleanStatus.dylib',dyn/'LocalCleanStatusAnimations.dylib',pref/'LocalCleanStatusPrefs',module/'LocalCleanStatusSystemActions',dyn/'LocalCleanStatusCellular.dylib',data/'LocalCleanStatusDataSwitch',payload/helper_path]
        report['binaries']=[macho(p,HELPER_ENTITLEMENTS if p==payload/helper_path else None) for p in binaries]
        for p in binaries:
            require(os.access(p,os.X_OK),'binary executable permission')
        report['files']=files
    out.mkdir(parents=True,exist_ok=True)
    (out/'VERIFICATION.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    return report
if __name__=='__main__':
    require(len(sys.argv)==3,'usage: verify_deb.py artifact.deb report-dir')
    inspect(Path(sys.argv[1]).resolve(),Path(sys.argv[2]).resolve())
