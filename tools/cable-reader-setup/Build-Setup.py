"""Build a self-contained Windows setup payload, with corresponding tool sources."""
from pathlib import Path
import argparse, hashlib, gzip, io, json, re, shutil, struct, subprocess, tarfile, zipfile

here=Path(__file__).resolve().parent
repo=here.parent.parent
parser=argparse.ArgumentParser()
parser.add_argument('--msys',type=Path,required=True)
parser.add_argument('--sources',type=Path,required=True)
parser.add_argument('--stage',type=Path,required=True)
args=parser.parse_args()
stage=args.stage.resolve();stage.mkdir(parents=True,exist_ok=True)
out=repo/'downloads';out.mkdir(exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def imports(path):
    d=path.read_bytes(); pe=struct.unpack_from('<I',d,60)[0]
    n=struct.unpack_from('<H',d,pe+6)[0];o=pe+24;s=struct.unpack_from('<H',d,pe+20)[0]
    directory=o+(112 if struct.unpack_from('<H',d,o)[0]==523 else 96)
    rva=struct.unpack_from('<I',d,directory+8)[0]
    sections=[struct.unpack_from('<IIII',d,o+s+i*40+8) for i in range(n)]
    def offset(r):
        for vs,va,rs,rp in sections:
            if va<=r<va+max(vs,rs): return rp+r-va
        raise ValueError('Invalid PE address')
    if not rva:return []
    pos=offset(rva);result=[]
    while any(d[pos:pos+20]):
        a=offset(struct.unpack_from('<I',d,pos+12)[0]);result.append(d[a:d.index(0,a)].decode());pos+=20
    return result

queue=['idevice_id.exe','ideviceinfo.exe','idevicediagnostics.exe'];files={}
while queue:
    name=queue.pop();key=name.lower();p=args.msys/'ucrt64/bin'/name
    if key in files:continue
    if not p.is_file():
        assert re.match(r'^(?:api-ms-win-|kernel32|advapi32|crypt32|iphlpapi|shell32|user32|ws2_32|ole32)',key),f'Unresolved dependency: {name}'
        continue
    files[key]=p;queue.extend(imports(p))

packages={}
for package in (args.msys/'var/lib/pacman/local').iterdir():
    mtree=package/'mtree'
    if not mtree.is_file():continue
    text=gzip.decompress(mtree.read_bytes()).decode()
    used=[]
    for key,p in files.items():
        match=re.search(r'^\./ucrt64/bin/'+re.escape(key)+r' .*?sha256digest=([0-9a-f]{64})',text,re.M|re.I)
        if match:
            assert sha(p)==match[1].lower(),f'Installed MSYS2 binary differs from package mtree: {p.name}'
            used.append(p.name)
    if used:
        desc=(package/'desc').read_text()
        def field(key):return desc.split('%'+key+'%\n')[1].split('\n\n')[0]
        packages[package.name]={'base':field('BASE'),'version':field('VERSION'),'license':field('LICENSE'),'files':used}
assert sum(len(p['files']) for p in packages.values())==len(files)

payload=stage/'payload';payload.mkdir(exist_ok=True)
for name in ['Install-Cable-Reader.ps1','Setup-Utilities.ps1']:
    shutil.copyfile(here/name,payload/name)
shutil.copyfile(here.parent/'dual-imei-reader/Update-Reader-Source.ps1',payload/'Update-Reader-Source.ps1')
shutil.copytree(here/'reader',payload/'reader',dirs_exist_ok=True)
apple=payload/'apple';apple.mkdir(exist_ok=True)
for p in files.values():shutil.copyfile(p,apple/p.name)
licenses=apple/'licenses';licenses.mkdir(exist_ok=True)
source_records=[]
sourcezip=out/'reader-sources.zip'
with zipfile.ZipFile(sourcezip,'w',zipfile.ZIP_STORED) as z:
    for name,package in sorted(packages.items()):
        base=package['base'];version=package['version'];archive=args.sources/(base+'-'+version+'.src.tar.zst')
        assert archive.is_file(),archive
        listing=subprocess.check_output(['tar','-tf',str(archive)],text=True).splitlines()
        inner=[p for p in listing if re.search(r'\.(tar\.(?:gz|bz2|xz)|tgz)$',p)]
        assert inner,f'Matching upstream source missing: {archive.name}'
        license_count=0
        for member in inner:
            data=subprocess.check_output(['tar','-xOf',str(archive),member])
            with tarfile.open(fileobj=io.BytesIO(data),mode='r:*') as tf:
                for m in tf.getmembers():
                    if m.isfile() and re.match(r'^(?:COPYING(?:\.LESSER|\.LIB)?|LICENSE(?:\.txt|\.md)?|NOTICE)$',Path(m.name).name,re.I):
                        content=tf.extractfile(m).read()
                        path=licenses/(base+'-'+Path(m.name).name)
                        path.write_bytes(content);license_count+=1
        assert license_count,f'No license found: {name}'
        z.write(archive,'sources/'+archive.name)
        url='https://mirror.msys2.org/mingw/sources/'+archive.name
        source_records.append({'package':name,'source':url,'sha256':sha(archive),**package})
    notice=('Greenloop cable reader: unmodified, dynamically linked MSYS2 tools.\n'
        'Each matching source archive contains upstream sources, patches and PKGBUILD build recipe.\n'
        'Extract with a zstd-aware tar, then build using MSYS2 UCRT64 and its package build tools.\n'
        'The separate DLL files may be replaced with compatible modified versions. You may modify and reverse engineer the LGPL components for debugging your modifications.\n'
        'The Greenloop launcher pins its PowerShell reader, not the iPhone DLLs. Keep copies of your custom libraries: rerunning setup restores packaged versions after backing up existing files.\n'
        'Licenses and copyright notices are included; no warranty is provided for the third-party tools.\n'
        'Official project: https://libimobiledevice.org/\nOfficial build distribution: https://www.msys2.org/\n')
    (apple/'THIRD-PARTY.txt').write_bytes(notice.encode())
    (apple/'tool-provenance.json').write_bytes((json.dumps(source_records,indent=2)+'\n').encode())
    z.writestr('README.txt',notice)
    z.writestr('tool-provenance.json',json.dumps(source_records,indent=2))
    for p in sorted(licenses.iterdir()):z.write(p,'licenses/'+p.name)

manifest={'version':'20261023-cable-setup-1','files':[{'path':p.relative_to(payload).as_posix(),'sha256':sha(p).upper()} for p in sorted(payload.rglob('*')) if p.is_file() and p.name!='payload.json']}
(payload/'payload.json').write_bytes((json.dumps(manifest,indent=2)+'\n').encode())
zip_path=stage/'payload.zip'
with zipfile.ZipFile(zip_path,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for p in sorted(payload.rglob('*')):
        if p.is_file():
            info=zipfile.ZipInfo(p.relative_to(payload).as_posix(),(2026,10,23,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED;z.writestr(info,p.read_bytes())
source=stage/'Setup.cs';source.write_bytes((here/'Setup.cs').read_text(encoding='utf-8').replace('PAYLOAD_SHA256',sha(zip_path)).encode())
exe=out/'Greenloop-Cable-Reader-Setup.exe'
subprocess.run([r'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe','/nologo','/target:winexe','/platform:x64','/optimize+',
    '/r:System.Windows.Forms.dll','/r:System.Drawing.dll','/r:System.Web.Extensions.dll','/r:System.IO.Compression.dll',
    '/resource:'+str(zip_path)+',payload.zip','/out:'+str(exe),str(source)],check=True)
record={'version':manifest['version'],'payloadSha256':sha(zip_path),'files':[{'path':p.name,'sha256':sha(p),'bytes':p.stat().st_size} for p in [exe,sourcezip]],'sources':source_records}
(out/'cable-setup-manifest.json').write_bytes((json.dumps(record,indent=2)+'\n').encode())
print(json.dumps({'exeBytes':exe.stat().st_size,'sourceBytes':sourcezip.stat().st_size,'payloadFiles':len(manifest['files']),'sha256':sha(exe)}))
