import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSEMBLER = ROOT / 'scripts' / 'assemble-app.sh'


class AppAssemblyTests(unittest.TestCase):
    """Guards the resource-seal defect that made Beta 1 launch as damaged."""

    def test_assembler_signs_the_completed_bundle_not_just_the_binary(self):
        script = ASSEMBLER.read_text()
        self.assertIn('codesign --force --deep --sign -', script)
        # The signature must be applied to the assembled .app so the resource
        # seal covers Info.plist and the bundled resources.
        self.assertIn('"$app"', script)
        self.assertIn('codesign --verify --deep --strict', script)

    def test_assembler_writes_the_info_plist_before_signing(self):
        script = ASSEMBLER.read_text()
        self.assertLess(script.index('Contents/Info.plist'), script.index('codesign --force'))

    def test_packaging_scripts_delegate_to_the_shared_assembler(self):
        for name in ('package-ci.sh', 'package-local.sh'):
            with self.subTest(script=name):
                self.assertIn('scripts/assemble-app.sh', (ROOT / 'scripts' / name).read_text())

    def test_public_release_requires_notarization_credentials(self):
        script = (ROOT / 'scripts' / 'package-ci.sh').read_text()
        self.assertIn('TRAYLET_NOTARY_KEY_PATH', script)
        self.assertIn('xcrun notarytool submit', script)
        self.assertIn('xcrun stapler staple', script)
        self.assertIn('spctl --assess', script)

    def test_ci_runs_a_runtime_smoke_test_on_the_packaged_app(self):
        workflow = (ROOT / '.github' / 'workflows' / 'macos-package.yml').read_text()
        self.assertIn('scripts/smoke-package.sh', workflow)
        smoke = (ROOT / 'scripts' / 'smoke-package.sh').read_text()
        # A valid signature alone does not prove the assembled bundle starts.
        self.assertIn('--v2-native-evidence', smoke)
        self.assertIn('codesign --verify --deep --strict', smoke)

    def test_release_channels_are_separated_by_tag(self):
        workflow = (ROOT / '.github' / 'workflows' / 'macos-package.yml').read_text()
        # An exact version tag requires Developer ID signing and notarization.
        self.assertIn('"$version-preview") channel="preview"', workflow)
        # The preview channel must skip the notarization gate but still run the
        # smoke test, and must label the release as unsigned.
        self.assertIn("endsWith(github.ref_name, '-preview')", workflow)
        self.assertIn('未使用 Developer ID 签名', workflow)


if __name__ == '__main__':
    unittest.main()
