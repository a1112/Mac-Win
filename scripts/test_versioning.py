#!/usr/bin/env python3
from pathlib import Path
import importlib.util,json,shutil,sys,tempfile,unittest,contextlib,io
ROOT=Path(__file__).resolve().parents[1]
SPEC=importlib.util.spec_from_file_location('native_version_manager',ROOT/'scripts/native_version_manager.py')
vm=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(vm)
class NativeVersionTests(unittest.TestCase):
 def fixture(self):
  temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup);dest=Path(temp.name)
  cfg=json.loads((ROOT/'versioning.json').read_text());paths={'versioning.json',*(s['path'] for s in cfg['units'].values())}
  for p in paths:(dest/p).parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/p,dest/p)
  return dest,cfg,paths
 def run_command(self,root,*args):
  with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):return vm.main(['--root',str(root),*args])
 def test_current_sources(self):self.assertTrue(vm.inspect(ROOT))
 def test_preview_apply_idempotency_and_independence(self):
  root,cfg,paths=self.fixture()
  for name,s in cfg['units'].items():
   with self.subTest(unit=name):
    records=vm.inspect(root);before={p:(root/p).read_bytes() for p in paths};version=records[name][-1];part='build' if s['format']=='build' else 'patch'
    self.assertEqual(0,self.run_command(root,'bump',part,'--unit',name));self.assertEqual(before,{p:(root/p).read_bytes() for p in paths})
    self.assertEqual(0,self.run_command(root,'bump',part,'--unit',name,'--expect',version,'--apply'))
    after=vm.inspect(root);self.assertNotEqual(version,after[name][-1])
    for other in records:
     if other!=name:self.assertEqual(records[other][-1],after[other][-1])
    updated={p:(root/p).read_bytes() for p in paths};self.assertEqual(0,self.run_command(root,'set',after[name][-1],'--unit',name,'--expect',after[name][-1],'--apply'));self.assertEqual(updated,{p:(root/p).read_bytes() for p in paths})
    for p,b in before.items():(root/p).write_bytes(b)
 def test_invalid_stale_and_missing_expected_are_nonmutating(self):
  root,cfg,paths=self.fixture();before={p:(root/p).read_bytes() for p in paths}
  for name in cfg['units']:
   for args in [('set','evil\ncommand','--unit',name,'--expect',vm.inspect(root)[name][-1],'--apply'),('set','0.0.0-rc.1','--unit',name,'--apply'),('bump','patch','--unit',name,'--expect','99999.0.0','--apply'),('bump','patch','--unit',name,'--apply')]:self.assertEqual(2,self.run_command(root,*args))
  self.assertEqual(before,{p:(root/p).read_bytes() for p in paths})
 def test_deleted_source_is_refused(self):
  root,cfg,paths=self.fixture();(root/next(iter(cfg['units'].values()))['path']).unlink();self.assertEqual(2,self.run_command(root,'check'))
 def test_symlink_source_is_refused(self):
  root,cfg,paths=self.fixture();p=root/next(iter(cfg['units'].values()))['path'];raw=p.read_bytes();target=root/'other.txt';target.write_bytes(raw);p.unlink();p.symlink_to(target);self.assertEqual(2,self.run_command(root,'check'))
 def test_ambiguous_native_field_is_refused(self):
  root,cfg,paths=self.fixture();s=next(iter(cfg['units'].values()));p=root/s['path'];text=p.read_text();a,b,value=vm.binding(text,s)
  if s['adapter']=='plist':text=text.replace('</dict>',f'<key>{s["key"]}</key><string>{value}</string></dict>',1)
  elif s['adapter']=='powershell-module':text+=f"    ModuleVersion = '{value}'\n"
  else:text=text.replace(f'"{s["key"]}": "{value}",',f'"{s["key"]}": "{value}",\n    "{s["key"]}": "{value}",',1)
  p.write_text(text);self.assertEqual(2,self.run_command(root,'check'))
 def test_effective_authority_drift_is_refused(self):
  root,cfg,paths=self.fixture();source=next(iter(cfg['units'].values()));p=root/source['path'];text=p.read_text()
  if source['adapter']=='powershell-module':
   text=text.replace("    ModuleVersion = '0.1.1'", '    ModuleVersion = "0.2.0"').replace('    PrivateData = @{', "    PrivateData = @{\n    ModuleVersion = '0.1.1'")
  elif source['adapter']=='embedded-plist':text=text.replace('path.write_bytes(plistlib.dumps(plist, sort_keys=False))', 'plist["CFBundleShortVersionString"] = "9.0.0"\npath.write_bytes(plistlib.dumps(plist, sort_keys=False))')
  else:text=text.replace('<key>CFBundleName</key>', '<!-- reviewed template changed -->\n<key>CFBundleName</key>')
  p.write_text(text);self.assertEqual(2,self.run_command(root,'check'))
 def test_macwin_baseline_remains_immutable(self):
  baseline=ROOT/'migration/baseline.json'
  if baseline.exists():
   cfg=json.loads(baseline.read_text());self.assertEqual(cfg['sourceCommit'],'db12d5ebc5ba0d5a29c9464d07c1a86ffbc47527');self.assertEqual(cfg['tag'],'mw-migration-baseline-db12d5e');self.assertNotIn('migration/baseline.json',[s['path'] for s in json.loads((ROOT/'versioning.json').read_text())['units'].values()])
if __name__=='__main__':unittest.main()
