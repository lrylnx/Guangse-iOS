#!/usr/bin/env python3
"""Build an unsigned device IPA for the user's external p12 re-signing workflow.
Does not create certificates, access private keys, or change Apple team identity.
"""
from pathlib import Path
import subprocess,plistlib,zipfile,json,hashlib,sys
root=Path(__file__).resolve().parents[1]
subprocess.run([sys.executable,str(root/'scripts/generate_project.py')],check=True)
log=root/'build-device.log'
with log.open('w') as stream:
 subprocess.run(['xcodebuild','-project',str(root/'LeicaPhoto.xcodeproj'),'-scheme','LeicaPhoto','-sdk','iphoneos','-configuration','Release','-derivedDataPath',str(root/'build-device'),'CODE_SIGNING_ALLOWED=NO','build'],stdout=stream,stderr=subprocess.STDOUT,check=True)
app=root/'build-device/Build/Products/Release-iphoneos/LeicaPhoto.app'
info=plistlib.loads((app/'Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='local.guangse.photo','Stable bundle identifier changed'
assert info['CFBundleSupportedPlatforms']==['iPhoneOS']
assert info['MinimumOSVersion']=='17.0'
for permission in ['NSCameraUsageDescription','NSPhotoLibraryAddUsageDescription']:
 assert info.get(permission),'Missing privacy usage description: '+permission
assert 'NSMicrophoneUsageDescription' not in info,'Photo-only camera must not request microphone'
assert 'arm64' in subprocess.check_output(['file',str(app/info['CFBundleExecutable'])],text=True)
for name in ['M9_low','M9_high','M9_colorfix','M9_distill']:
 model=app/(name+'.mlmodelc')
 assert model.is_dir() and any(p.is_file() and p.stat().st_size>1000 for p in model.rglob('*')),'Missing compiled model: '+name
filters=json.loads((app/'filters.json').read_text())
assert len(filters)==49
for item in filters:
 suffix='.lut' if item['kind']=='clu1' else '.plut'
 assert (app/(item['resource']+suffix)).is_file()
assert (app/'m9-parameters.json').is_file()
metadata=json.loads((app/'Metadata.appintents/extract.actionsdata').read_text())
intent=metadata['actions']['GeneratePhotosIntent']
assert intent['isDiscoverable'] and intent['openAppWhenRun'],'Shortcut must run in foreground app'
parameter=next(p for p in intent['parameters'] if p['name']=='photos')
assert 'array' in parameter['valueType'] and parameter['isInput'] and not parameter['isOptional']
assert 'public.image' in json.dumps(parameter),'Shortcut must accept shared images'
assert any(s['actionIdentifier']=='GeneratePhotosIntent' for s in metadata['autoShortcuts'])

assert not (app/'_CodeSignature').exists(),'Unexpected stale signature in unsigned artifact'
output=Path(sys.argv[1]) if len(sys.argv)>1 else (Path.home()/'Desktop')/f"光色-{info['CFBundleShortVersionString']}-M9AI-待签名.ipa"
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
 for p in sorted(app.rglob('*')):
  if p.is_file():archive.write(p,'Payload/LeicaPhoto.app/'+str(p.relative_to(app)))
with zipfile.ZipFile(output) as archive:assert archive.testzip() is None
record={'ipa':str(output),'bytes':output.stat().st_size,'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'bundleID':info['CFBundleIdentifier'],'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'signing':'unsigned; external p12 + matching provisioning profile required','models':['M9_low','M9_high','M9_colorfix','M9_distill'],'filters':len(filters),'camera':'quality-priority still capture; original bytes + processed PNG; device validation pending','shortcut':'GeneratePhotosIntent; shared image array; foreground; metadata verified; device validation pending','hdr':'source luminance gain reconstruction; 16-bit PQ PNG and HDR preview; device validation pending'}
(root/'release-manifest.json').write_text(json.dumps(record,ensure_ascii=False,indent=2))
print(json.dumps(record,ensure_ascii=False,indent=2))
