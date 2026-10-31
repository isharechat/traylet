import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

WRAPPER = Path(__file__).resolve().parents[2]/'scripts/swift-local.sh'


class SwiftWrapperTests(unittest.TestCase):
    def arguments(self, *arguments):
        with tempfile.TemporaryDirectory(prefix='traylet-wrapper-') as temp:
            root = Path(temp); (root/'scripts').mkdir(); (root/'bin').mkdir()
            shutil.copy2(WRAPPER, root/'scripts/swift-local.sh')
            fake = root/'bin/swift'
            fake.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
            fake.chmod(0o755)
            env = dict(os.environ); env['PATH'] = str(root/'bin')+os.pathsep+env['PATH']
            result = subprocess.run([root/'scripts/swift-local.sh', *arguments], env=env, capture_output=True, text=True, check=True)
            return json.loads(result.stdout)

    def test_package_description_has_local_caches_but_no_unsupported_sdk_option(self):
        args = self.arguments('package', 'describe', '--type', 'json')
        self.assertNotIn('--sdk', args)
        self.assertIn('--cache-path', args)
        self.assertIn('describe', args)

    def test_build_still_uses_explicit_sdk(self):
        self.assertIn('--sdk', self.arguments('build'))
