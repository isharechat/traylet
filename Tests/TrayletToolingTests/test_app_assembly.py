import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSEMBLER = ROOT / 'scripts' / 'package' / 'assemble-app.sh'


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
        self.assertIn('TrayletUpdateFeedURL', script)

    def test_packaging_scripts_delegate_to_the_shared_assembler(self):
        for name in ('package-ci.sh', 'package-local.sh'):
            with self.subTest(script=name):
                self.assertIn('scripts/package/assemble-app.sh', (ROOT / 'scripts' / 'package' / name).read_text())

    def test_public_release_requires_notarization_credentials(self):
        script = (ROOT / 'scripts' / 'package' / 'package-ci.sh').read_text()
        self.assertIn('TRAYLET_NOTARY_KEY_PATH', script)
        self.assertIn('xcrun notarytool submit', script)
        self.assertIn('xcrun stapler staple', script)
        self.assertIn('spctl --assess', script)

    def test_ci_runs_a_runtime_smoke_test_on_the_packaged_app(self):
        workflow = (ROOT / '.github' / 'workflows' / 'build-and-publish.yml').read_text()
        self.assertIn('scripts/package/smoke-package.sh', workflow)
        self.assertIn('scripts/package/package-ci.sh', workflow)
        smoke = (ROOT / 'scripts' / 'package' / 'smoke-package.sh').read_text()
        # A valid signature alone does not prove the assembled bundle starts.
        self.assertIn('--v2-native-evidence', smoke)
        self.assertIn('codesign --verify --deep --strict', smoke)

    def test_release_channels_are_separated_by_tag(self):
        wrapper = (ROOT / '.github' / 'workflows' / 'macos-package.yml').read_text()
        shared = (ROOT / '.github' / 'workflows' / 'build-and-publish.yml').read_text()
        # An exact version tag maps to the signed channel; a -preview tag to preview.
        self.assertIn('"$version") mode="release-signed"', wrapper)
        self.assertIn('"$version-preview") mode="release-preview"', wrapper)
        # The preview channel skips the notarization gate: Developer ID signing
        # runs only in the signed mode.
        self.assertIn("inputs.mode == 'release-signed'", shared)
        # The preview release must be labelled as unsigned.
        self.assertIn('未使用 Developer ID 签名', wrapper)

    def test_every_build_packages_and_uploads_an_artifact(self):
        workflow = (ROOT / '.github' / 'workflows' / 'build-and-publish.yml').read_text()
        self.assertIn('uses: actions/upload-artifact@v4', workflow)
        # Packaging and uploading must not be gated behind release modes: every
        # build (PR, manual dispatch, tag, merge) uploads an artifact.
        self.assertNotIn('if: inputs.mode !=', workflow)


if __name__ == '__main__':
    unittest.main()
