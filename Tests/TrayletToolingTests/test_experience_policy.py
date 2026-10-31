import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]/'scripts'))
from installing.experience_policy import experience_scope, experience_blockers


class ExperiencePolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='traylet-experience-policy-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ['Sources/TrayletApp/Main.swift', 'Sources/TrayletCore/Domain.swift',
                     'Sources/TrayletApp/Capture/Scrolling/Stub.swift', 'Tests/TrayletAppTests/Ready.swift',
                     'Tests/TrayletAppTests/Scrolling/StubTests.swift']:
            p = self.root/name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('// synthetic')
        self.description = {'targets': [
            {'name': 'TrayletApp', 'path': 'Sources/TrayletApp', 'sources': ['Main.swift']},
            {'name': 'TrayletCore', 'path': 'Sources/TrayletCore', 'sources': ['Domain.swift']},
            {'name': 'TrayletAppTests', 'path': 'Tests/TrayletAppTests', 'sources': ['Ready.swift']}]}

    def test_scope_records_only_compiled_sources_and_preserves_excluded_hashes(self):
        scope = experience_scope(self.root, self.description)
        self.assertEqual(len(scope['compiledSwiftFiles']), 3)
        self.assertEqual(set(scope['excludedDevelopmentFiles']), {
            'Sources/TrayletApp/Capture/Scrolling/Stub.swift', 'Tests/TrayletAppTests/Scrolling/StubTests.swift'})

    def test_accidentally_compiling_deferred_code_is_rejected(self):
        self.description['targets'][0]['sources'].append('Capture/Scrolling/Stub.swift')
        with self.assertRaises(RuntimeError): experience_scope(self.root, self.description)

    def test_omitting_completed_source_is_rejected(self):
        self.description['targets'][1]['sources'] = []
        with self.assertRaises(RuntimeError): experience_scope(self.root, self.description)

    def test_escaping_source_path_is_rejected(self):
        self.description['targets'][0]['sources'] = ['../../outside.swift']
        with self.assertRaises(RuntimeError): experience_scope(self.root, self.description)

    def test_only_matching_passed_offscreen_report_can_release_local_experience(self):
        counts = {'successful': 3, 'failed': 0, 'skipped': 1, 'total': 4}
        valid = {'passed': True, 'scope': 'syntheticOffscreen', 'binarySHA256': 'current'}
        self.assertEqual(experience_blockers(counts, [valid], 'current'), [])
        for reports in [[], [{**valid, 'binarySHA256': 'old'}], [{**valid, 'passed': False}], [{**valid, 'scope': 'other'}]]:
            self.assertTrue(experience_blockers(counts, reports, 'current'))
        self.assertTrue(experience_blockers({**counts, 'failed': 1}, [valid], 'current'))
        self.assertTrue(experience_blockers({**counts, 'successful': 0}, [valid], 'current'))


if __name__ == '__main__': unittest.main()
