#!/usr/bin/env python3
"""Explicit native metadata bindings; Python 3.11+, no network or package install."""
from __future__ import annotations
import argparse, ast, json, os, re, stat, tempfile, plistlib, hashlib
from pathlib import Path
import xml.etree.ElementTree as ET

class VersionError(ValueError): pass

def safe_path(root, relative):
    p=Path(relative)
    if p.is_absolute() or not p.parts or any(x in ('.','..','.git') for x in p.parts): raise VersionError('Unsafe metadata path')
    result=root/p
    for item in (result,*result.parents):
        if item.is_symlink(): raise VersionError('Symlink metadata paths are refused')
        if item==root: break
    if not result.is_file(): raise VersionError('Metadata source must be an existing file')
    return result

def value_key(value,kind):
    pattern=r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)' if kind=='marketing' else r'[1-9][0-9]*'
    if not isinstance(value,str) or not re.fullmatch(pattern,value): raise VersionError('Expected numeric X.Y.Z marketing version or positive integer build number')
    return tuple(map(int,value.split('.')))

def binding(text,source):
    kind=source['adapter']; key=source['key']
    if kind=='plist':
        parsed=plistlib.loads(text.encode()); root=ET.fromstring(text)
        if len(root)!=1 or root[0].tag!='dict': raise VersionError('Expected one top-level plist dictionary')
        nodes=list(root[0]); matches=[i for i,x in enumerate(nodes) if x.tag=='key' and x.text==key]
        if len(matches)!=1 or matches[0]+1>=len(nodes) or nodes[matches[0]+1].tag!='string': raise VersionError('Expected exactly one string plist field')
        matches=list(re.finditer(r'<key>'+re.escape(key)+r'</key>\s*<string>([^<>]*)</string>',text))
        if len(matches)!=1 or matches[0][1]!=parsed.get(key): raise VersionError('Plist binding is ambiguous')
        m=matches[0]; return m.start(1),m.end(1),m[1]
    if kind=='powershell-module':
        if key!='ModuleVersion' or '<#' in text or '#>' in text or '@"' in text or "@'" in text: raise VersionError('Unsupported PowerShell manifest')
        matches=list(re.finditer(r"^    ModuleVersion = '([^'\r\n]+)'$",text,re.M))
        if len(matches)!=1: raise VersionError('Expected one exact ModuleVersion declaration')
        m=matches[0]; return m.start(1),m.end(1),m[1]
    if kind=='embedded-plist':
        marker="/usr/bin/python3 - \"$PLIST\" <<'PY'\n"
        if text.count(marker)!=1: raise VersionError('Expected exact packaging Python heredoc')
        start=text.index(marker)+len(marker);end=text.find('\nPY\n',start)
        if end<0:raise VersionError('Unterminated packaging heredoc')
        code=text[start:end];tree=ast.parse(code); values=[]
        for node in tree.body:
            if isinstance(node,ast.Assign) and len(node.targets)==1 and isinstance(node.targets[0],ast.Name) and node.targets[0].id=='plist' and isinstance(node.value,ast.Dict):
                values += [v for k,v in zip(node.value.keys,node.value.values) if isinstance(k,ast.Constant) and k.value==key]
        if len(values)!=1 or not isinstance(values[0],ast.Constant) or not isinstance(values[0].value,str): raise VersionError('Expected one literal field in the generated plist')
        node=values[0];lines=code.splitlines(keepends=True)
        a=sum(len(x) for x in lines[:node.lineno-1])+len(lines[node.lineno-1].encode()[:node.col_offset].decode())
        b=sum(len(x) for x in lines[:node.end_lineno-1])+len(lines[node.end_lineno-1].encode()[:node.end_col_offset].decode())
        token=code[a:b]
        if token!=json.dumps(node.value):raise VersionError('Only exact double-quoted native plist literals are supported')
        return start+a+1,start+b-1,node.value
    raise VersionError('Unsupported native source adapter')

def inspect(root):
    config=json.loads(safe_path(root,'versioning.json').read_text())
    if set(config)!={'schema_version','units','notes','source_fingerprints'} or config['schema_version']!=1:raise VersionError('Invalid configuration')
    result={}
    for name,source in config['units'].items():
        if set(source)!={'path','adapter','key','format'} or source['format'] not in ('marketing','build'):raise VersionError('Invalid source binding')
        if source['key'] not in ('CFBundleShortVersionString','CFBundleVersion','ModuleVersion'):raise VersionError('Only explicit native product version fields are supported')
        path=safe_path(root,source['path']);raw=path.read_bytes();a,b,value=binding(raw.decode('utf-8'),source);value_key(value,source['format'])
        result[name]=(source,path,raw,a,b,value)
    fingerprints=config['source_fingerprints']
    if not isinstance(fingerprints,dict) or set(fingerprints)!={r[0]['path'] for r in result.values()}:raise VersionError('Expected one fingerprint per native source')
    for relative,expected in fingerprints.items():
        records=[r for r in result.values() if r[0]['path']==relative]
        text=records[0][2].decode('utf-8');last=len(text)+1
        for source,_,_,a,b,_ in sorted(records,key=lambda r:r[3],reverse=True):
            if b>last:raise VersionError('Overlapping native bindings')
            text=text[:a]+'<VERSION:'+source['key']+'>'+text[b:];last=a
        if not isinstance(expected,str) or hashlib.sha256(text.encode()).hexdigest()!=expected:raise VersionError('Native source template changed; review effective authority and update its masked fingerprint')
    return result

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--root',default='.')
    sub=parser.add_subparsers(dest='command',required=True)
    for command in ('check','show','set','bump'):
        p=sub.add_parser(command);p.add_argument('--unit')
        if command in ('set','bump'):
            p.add_argument('value');p.add_argument('--expect');p.add_argument('--apply',action='store_true')
    args=parser.parse_args(argv)
    try:
        root=Path(os.path.abspath(args.root))
        if any(x.is_symlink() for x in (root,*root.parents)):raise VersionError('Symlink roots are refused')
        records=inspect(root)
        if args.command in ('check','show'):
            print(json.dumps({'status':'ok','units':{k:v[-1] for k,v in records.items()}},indent=2));return 0
        if args.unit not in records:raise VersionError('Select one exact --unit from show')
        source,path,raw,a,b,current=records[args.unit]
        if args.expect is not None and args.expect!=current:raise VersionError('Expected current version does not match')
        if args.apply and args.expect is None:raise VersionError('--apply requires --expect CURRENT')
        target=args.value
        if args.command=='bump':
            if source['format']=='build':
                if target!='build':raise VersionError('Build number supports bump build only')
                target=str(int(current)+1)
            else:
                parts=list(value_key(current,'marketing'))
                if target not in ('major','minor','patch'):raise VersionError('Marketing version supports major, minor or patch')
                i=('major','minor','patch').index(target);parts[i]+=1;parts[i+1:]=[0]*(2-i);target='.'.join(map(str,parts))
        if value_key(target,source['format'])<value_key(current,source['format']):raise VersionError('Native version downgrade refused')
        text=raw.decode();updated=(text[:a]+target+text[b:]).encode();binding(updated.decode(),source)
        if args.apply and updated!=raw:
            # Validate every source before the first write, then compare all snapshots again.
            for _,(_,p,before,_,_,_) in records.items():
                if p.read_bytes()!=before:raise VersionError('Source changed since validation')
            fd,tmp=tempfile.mkstemp(prefix='.version-',dir=path.parent)
            try:
                with os.fdopen(fd,'wb') as stream:stream.write(updated);stream.flush();os.fsync(stream.fileno())
                os.chmod(tmp,stat.S_IMODE(path.stat().st_mode))
                if path.read_bytes()!=raw:raise VersionError('Source changed before replacement')
                os.replace(tmp,path)
            finally:
                if os.path.exists(tmp):os.unlink(tmp)
        print(json.dumps({'unit':args.unit,'from':current,'to':target,'files':[source['path']] if updated!=raw else [],'mode':'apply' if args.apply else 'dry-run','changed':updated!=raw},indent=2));return 0
    except (ValueError,OSError,SyntaxError,KeyError,TypeError,ET.ParseError,plistlib.InvalidFileException) as e:
        print('native-version-manager: '+str(e),file=__import__('sys').stderr);return 2
if __name__=='__main__':raise SystemExit(main())
