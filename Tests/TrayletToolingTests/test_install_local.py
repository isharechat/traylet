import importlib.util
import plistlib
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/installing/install_core.py'

class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='traylet-install-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.bundle(self.root/'release/Traylet.app', '0.1.2', b'NEW VERIFIED')
        self.target = self.bundle(self.root/'Applications/Traylet.app', '0.1.0', b'OLD RECOVERABLE')
        self.backups = self.root/'Applications/.Traylet-backups'
    def bundle(self, path, version, data, identifier='local.traylet.app'):
        (path/'Contents/MacOS').mkdir(parents=True)
        (path/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier, 'CFBundleShortVersionString':version,'CFBundleVersion':'3','CFBundleExecutable':'Traylet'}))
        (path/'Contents/MacOS/Traylet').write_bytes(data)
        return path
    def load_core(self):
        spec=importlib.util.spec_from_file_location('traylet_install_core', SCRIPT)
        module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
        return module
    def inventory(self, apps=None, available=True):
        return {'available':available,'apps':apps or []}
    def install(self, core, inventories=None, validator=None):
        results=iter(inventories or [self.inventory(),self.inventory()])
        return core.replace_installed(self.source,self.target,self.backups,
            inventory=lambda:next(results),validate=validator or (lambda p: None),copy_bundle=shutil.copytree)
    def test_running_target_is_staged_without_replacing_or_touching_its_edit_state(self):
        core=self.load_core()
        old=(self.target/'Contents/MacOS/Traylet').read_bytes()
        result=self.install(core,[self.inventory([{'bundlePath':str(self.target),'pid':42,'unsavedEdits':'unknown'}])])
        self.assertEqual(result['status'],'staged_running')
        self.assertEqual((self.target/'Contents/MacOS/Traylet').read_bytes(),old)
        self.assertFalse(self.backups.exists())
    def test_atomic_replacement_retains_the_exact_old_app_in_backup(self):
        core=self.load_core();result=self.install(core)
        self.assertEqual(result['status'],'installed')
        self.assertEqual((self.target/'Contents/MacOS/Traylet').read_bytes(),b'NEW VERIFIED')
        self.assertEqual((Path(result['backup'])/'Contents/MacOS/Traylet').read_bytes(),b'OLD RECOVERABLE')
    def test_post_swap_validation_failure_rolls_back_old_app(self):
        core=self.load_core()
        def reject_live_new(path):
            if path==self.target and (path/'Contents/MacOS/Traylet').read_bytes()==b'NEW VERIFIED': raise RuntimeError('synthetic validation failure')
        with self.assertRaisesRegex(RuntimeError,'synthetic validation failure'):
            self.install(core,validator=reject_live_new)
        self.assertEqual((self.target/'Contents/MacOS/Traylet').read_bytes(),b'OLD RECOVERABLE')
    def test_app_launch_between_copy_and_commit_refuses_update(self):
        core=self.load_core()
        result=self.install(core,[self.inventory(),self.inventory([{'bundlePath':str(self.target),'pid':7}])])
        self.assertEqual(result['status'],'staged_running')
        self.assertEqual((self.target/'Contents/MacOS/Traylet').read_bytes(),b'OLD RECOVERABLE')
    def test_unknown_runtime_inventory_fails_closed_without_mutation(self):
        core=self.load_core()
        with self.assertRaisesRegex(RuntimeError,'运行状态'):
            self.install(core,[self.inventory(available=False)])
        self.assertEqual((self.target/'Contents/MacOS/Traylet').read_bytes(),b'OLD RECOVERABLE')
    def test_other_traylet_instance_does_not_get_closed_or_launched_twice(self):
        core=self.load_core();row={'bundlePath':str(self.root/'elsewhere/Traylet.app'),'pid':55}
        result=self.install(core,[self.inventory([row]),self.inventory([row])])
        self.assertEqual(result['status'],'installed')
        self.assertEqual(result['runningApps'],[row])
        self.assertFalse(result['mayLaunch'])
    def test_unrelated_target_is_never_overwritten(self):
        core=self.load_core()
        p=self.target/'Contents/Info.plist';info=plistlib.loads(p.read_bytes());info['CFBundleIdentifier']='other.app';p.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(RuntimeError,'其他应用'):
            self.install(core)
        self.assertEqual((self.target/'Contents/MacOS/Traylet').read_bytes(),b'OLD RECOVERABLE')
    def test_automatic_downgrade_is_rejected_and_old_version_stays(self):
        core=self.load_core()
        p=self.target/'Contents/Info.plist';v=plistlib.loads(p.read_bytes());v['CFBundleShortVersionString']='0.2.0';p.write_bytes(plistlib.dumps(v))
        with self.assertRaisesRegex(RuntimeError,'较新版本'):
            self.install(core)
        self.assertEqual((self.target/'Contents/MacOS/Traylet').read_bytes(),b'OLD RECOVERABLE')
    def test_copy_failure_never_changes_installed_app(self):
        core=self.load_core()
        def failed_copy(source,target): raise OSError('synthetic copy failure')
        with self.assertRaisesRegex(OSError,'synthetic copy failure'):
            core.replace_installed(self.source,self.target,self.backups,inventory=lambda:self.inventory(),validate=lambda p:None,copy_bundle=failed_copy)
        self.assertEqual((self.target/'Contents/MacOS/Traylet').read_bytes(),b'OLD RECOVERABLE')
    def test_install_from_absent_target_keeps_exact_verified_bytes(self):
        core=self.load_core();shutil.rmtree(self.target)
        result=self.install(core)
        self.assertIsNone(result['backup'])
        self.assertEqual((self.target/'Contents/MacOS/Traylet').read_bytes(),b'NEW VERIFIED')
    def test_recent_explicit_exit_confirmation_can_resolve_unknown_for_this_install(self):
        core=self.load_core()
        result=core.replace_installed(self.source,self.target,self.backups,
            inventory=lambda:self.inventory(available=False),validate=lambda p:None,
            confirmed_exit_at=datetime.now(timezone.utc).isoformat())
        self.assertEqual(result['status'],'installed')
        self.assertEqual((Path(result['backup'])/'Contents/MacOS/Traylet').read_bytes(),b'OLD RECOVERABLE')
    def test_expired_exit_confirmation_does_not_override_unknown(self):
        core=self.load_core()
        with self.assertRaisesRegex(RuntimeError,'确认'):
            core.replace_installed(self.source,self.target,self.backups,
                inventory=lambda:self.inventory(available=False),validate=lambda p:None,
                confirmed_exit_at=(datetime.now(timezone.utc)-timedelta(minutes=16)).isoformat())
        self.assertEqual((self.target/'Contents/MacOS/Traylet').read_bytes(),b'OLD RECOVERABLE')
    def test_explicit_exit_never_overrides_a_known_running_target(self):
        core=self.load_core()
        result=core.replace_installed(self.source,self.target,self.backups,
            inventory=lambda:self.inventory([{'bundlePath':str(self.target),'pid':42}]),validate=lambda p:None,
            confirmed_exit_at=datetime.now(timezone.utc).isoformat())
        self.assertEqual(result['status'],'staged_running')
    def test_new_instance_after_copy_wins_over_exit_confirmation(self):
        core=self.load_core();observations=iter([self.inventory(available=False),self.inventory([{'bundlePath':str(self.target),'pid':42}])])
        result=core.replace_installed(self.source,self.target,self.backups,
            inventory=lambda:next(observations),validate=lambda p:None,
            confirmed_exit_at=datetime.now(timezone.utc).isoformat())
        self.assertEqual(result['status'],'staged_running')
        self.assertEqual((self.target/'Contents/MacOS/Traylet').read_bytes(),b'OLD RECOVERABLE')
