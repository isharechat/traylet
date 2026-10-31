import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/record-build-manifest.py'

class ManifestEvidenceTests(unittest.TestCase):
    def run_manifest(self, log, newer_source=False, newer_test=False, candidate=False):
        with tempfile.TemporaryDirectory(prefix='traylet-manifest-test-') as temp:
            root = Path(temp)
            for directory in ('scripts', '.build', 'build/evidence', 'build/candidate/Traylet.app/Contents/MacOS'):
                (root / directory).mkdir(parents=True, exist_ok=True)
            shutil.copy2(SCRIPT, root / 'scripts/record-build-manifest.py')
            (root / 'assets/brand').mkdir(parents=True)
            for name in ('Package.swift', 'AGENTS.md', 'assets/brand/Traylet.icns', 'build/candidate/Traylet.app/Contents/Info.plist', 'build/candidate/Traylet.app/Contents/MacOS/Traylet'):
                (root / name).write_text('SYNTHETIC FIXTURE')
            for name in ('VERSION', 'BUILD_NUMBER', 'THIRD_PARTY_NOTICES.md'):
                (root / name).write_text('SYNTHETIC FIXTURE')
            if newer_source:
                (root / 'Sources').mkdir()
                source = root / 'Sources/New.swift'
                source.write_text('// SYNTHETIC FIXTURE')
                os.utime(root / 'build/candidate/Traylet.app/Contents/MacOS/Traylet', ns=(1, 1))
                os.utime(source, ns=(2, 2))
            (root / '.build/test-results.xml').write_text('<testsuites><testsuite><testcase name="pass"/><testcase name="skip"><skipped/></testcase></testsuite></testsuites>')
            if newer_test:
                directory = root / 'Tests/TrayletAppTests'
                directory.mkdir(parents=True)
                source = directory / 'Late.swift'
                source.write_text('// SYNTHETIC LATE TEST')
                stamp = time.time_ns()
                os.utime(root / '.build/test-results.xml', ns=(stamp, stamp))
                os.utime(source, ns=(stamp+1_000_000, stamp+1_000_000))
                os.utime(root / 'build/candidate/Traylet.app/Contents/MacOS/Traylet', ns=(stamp+2_000_000, stamp+2_000_000))
            (root / '.build/latest-tests.log').write_text(log)
            target = root / 'build/evidence/build-manifest.json'
            target.write_text('UNCHANGED BASELINE')
            arguments = ['python3', str(root / 'scripts/record-build-manifest.py')]
            if candidate:
                app = root / 'build/review/Traylet.app'
                shutil.copytree(root / 'build/candidate/Traylet.app', app)
                (app / 'Contents/MacOS/Traylet').write_bytes(b'INDEPENDENT CANDIDATE')
                (root / 'build/review/evidence').mkdir()
                (root / 'build/review/evidence/evidence-report.json').write_text('{"passed": true}')
                shutil.copy2(root / '.build/test-results.xml', root / '.build/review.xml')
                shutil.copy2(root / '.build/latest-tests.log', root / '.build/review.log')
                arguments += ['--app-path', str(app), '--output', str(root / 'build/review/build-manifest.json'),
                              '--test-results', str(root / '.build/review.xml'), '--test-log', str(root / '.build/review.log')]
            result = subprocess.run(arguments, capture_output=True, text=True, timeout=5)
            if candidate:
                self.assertEqual(target.read_text(), 'UNCHANGED BASELINE')
                target = root / 'build/review/build-manifest.json'
            return result, target.read_text()


    def test_independent_candidate_uses_its_own_binary_and_evidence_and_preserves_old_manifest(self):
        result, saved = self.run_manifest('Test run with 2 tests in 1 suite passed after 0.1 seconds.\n', candidate=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(saved)
        self.assertEqual(manifest['applicationPath'], 'build/review/Traylet.app')
        self.assertEqual(manifest['binarySHA256'], hashlib.sha256(b'INDEPENDENT CANDIDATE').hexdigest())
        self.assertEqual(manifest['testResultsPath'], '.build/review.xml')
        self.assertEqual(manifest['testLogPath'], '.build/review.log')
        self.assertEqual(manifest['candidateNativeReports'], {
            'build/review/evidence/evidence-report.json': hashlib.sha256(b'{"passed": true}').hexdigest()
        })

    def test_failed_build_cannot_recertify_stale_passing_xml(self):
        result, saved = self.run_manifest('error: Build failed\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Latest test log does not show a completed passing run', result.stderr)
        self.assertEqual(saved, 'UNCHANGED BASELINE')

    def test_fresh_consistent_counts_include_skips(self):
        result, saved = self.run_manifest('Test run with 2 tests in 1 suite passed after 0.1 seconds.\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(saved)['testCountsFromTestcaseElements'], {'total':2, 'successful':1, 'skipped':1, 'failed':0})

    def test_inconsistent_xml_and_log_do_not_overwrite_baseline(self):
        result, saved = self.run_manifest('Test run with 3 tests in 1 suite passed after 0.1 seconds.\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(saved, 'UNCHANGED BASELINE')

    def test_sources_newer_than_packaged_binary_do_not_recertify_old_app(self):
        result, saved = self.run_manifest('Test run with 2 tests in 1 suite passed after 0.1 seconds.\n', newer_source=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('newer than the packaged binary', result.stderr)
        self.assertEqual(saved, 'UNCHANGED BASELINE')

    def test_late_test_added_before_repackaging_still_requires_new_test_run(self):
        result, saved = self.run_manifest('Test run with 2 tests in 1 suite passed after 0.1 seconds.\n', newer_test=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('newer than the test results', result.stderr)
        self.assertEqual(saved, 'UNCHANGED BASELINE')

    def test_manifest_keeps_release_blockers_so_install_refuses_it(self):
        result, saved = self.run_manifest('Test run with 2 tests in 1 suite passed after 0.1 seconds.\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(saved)
        self.assertEqual(manifest['sourceGeneration'], 'v2')
        self.assertIs(manifest['deliveryEligible'], False)
        self.assertTrue(manifest['deliveryBlockers'])

if __name__ == '__main__':
    unittest.main()
