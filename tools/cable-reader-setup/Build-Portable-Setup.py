"""Update the portable ZIP while preserving the verified third-party/reader payload."""
from pathlib import Path, PurePosixPath
import argparse, hashlib, json, zipfile
repo=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser();parser.add_argument('--base-zip',type=Path,required=True);args=parser.parse_args()
sha=lambda b:hashlib.sha256(b).hexdigest().upper()
with zipfile.ZipFile(args.base_zip)as z:
    if len(set(z.namelist()))!=len(z.namelist()):raise ValueError('Duplicate ZIP entry')
    payload={n:z.read(n)for n in z.namelist()}
for name in payload:
    p=PurePosixPath(name)
    if p.is_absolute()or '..'in p.parts or '\\'in name or ':'in name:raise ValueError('Unsafe ZIP entry')
manifest=json.loads(payload['payload.json'])
if manifest['version']not in ['20261112-stable-cable-setup-1','20261117-reader-autostart-1']:raise ValueError('Unrecognized portable baseline')
if not all(sha(payload[f['path']])==f['sha256']for f in manifest['files']):raise ValueError('Baseline payload hash differs')
for name in ['Install-Cable-Reader.ps1','Reader-Autostart.ps1','Repair-Autostart.ps1']:
    payload[name]=(Path(__file__).parent/name).read_bytes()
payload['Repair-Autostart.cmd']=b'@echo off\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-Autostart.ps1"\r\nif errorlevel 1 echo Auto-start repair did not finish. Share the message above.\r\npause\r\n'
payload['README.txt']=b'Greenloop Cable Reader: install once using Install-Greenloop.cmd.\r\nExisting working reader: run Repair-Autostart.cmd once to repair Windows sign-in startup without reinstalling phone tools.\r\nLog in to your normal Windows account after restart; background reader starts automatically, also on battery power.\r\nNo phone stock or business records are changed. Unlock the connected phone and approve Trust / USB debugging.\r\n'
manifest.update(version='20261117-reader-autostart-1',autostartVersion='20261117-reader-autostart-1')
manifest['files']=[{'path':n,'sha256':sha(b)}for n,b in sorted(payload.items())if n!='payload.json']
payload['payload.json']=(json.dumps(manifest,indent=2)+'\n').encode()
out=repo/'downloads/Greenloop-Cable-Reader-Setup.zip'
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED,compresslevel=9)as z:
    for n,b in sorted(payload.items()):z.writestr(zipfile.ZipInfo(n,(2026,11,17,0,0,0)),b,compress_type=zipfile.ZIP_DEFLATED)
p=repo/'downloads/cable-setup-manifest.json';data=json.loads(p.read_text(encoding='utf8'));data['portableSetup']={'version':manifest['version'],'path':out.name,'sha256':sha(out.read_bytes()).lower(),'bytes':out.stat().st_size};p.write_text(json.dumps(data,indent=2)+'\n',encoding='utf8',newline='\n')
print('Verified portable ZIP:',len(payload),'files;',out.stat().st_size,'bytes')
