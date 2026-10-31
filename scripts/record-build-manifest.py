#!/usr/bin/env python3
"""Record reproducible local evidence; this does not run or certify missing checks."""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import hashlib
import json
import re
import subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--app-path', type=Path, default=root / 'build/candidate/Traylet.app')
parser.add_argument('--output', type=Path, default=root / 'build/evidence/build-manifest.json')
parser.add_argument('--test-results', type=Path, default=root / '.build/test-results.xml')
parser.add_argument('--test-log', type=Path, default=root / '.build/latest-tests.log')
parser.add_argument('--local-experience', action='store_true', help='Explicit stage11 local trial, with deferred scrolling excluded by SwiftPM.')
args = parser.parse_args()
app_path = args.app_path.resolve()
if not app_path.is_relative_to((root / 'build').resolve()) or app_path.suffix != '.app':
    raise RuntimeError('App path must be an .app inside this project build directory.')
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

xml = args.test_results.resolve()
cases = ET.parse(xml).getroot().findall('.//testcase')
counts = {'total': len(cases), 'successful': 0, 'skipped': 0, 'failed': 0}
for case in cases:
    if case.find('skipped') is not None:
        counts['skipped'] += 1
    elif case.find('failure') is not None or case.find('error') is not None:
        counts['failed'] += 1
    else:
        counts['successful'] += 1
if not cases or counts['failed']:
    raise RuntimeError(f'Cannot record a passing test manifest: {counts}')
log = args.test_log.read_text()
suite = re.search(r'Test run with (\d+) tests in (\d+) suites? passed', log)
if suite is None:
    raise RuntimeError('Latest test log does not show a completed passing run; stale XML is not evidence.')
if int(suite.group(1)) != counts['total']:
    raise RuntimeError('Latest test log and XML testcase counts differ; preserve the previous manifest.')
# Default records all provenance. The explicit experience profile distinguishes compiled and deferred inputs.
scope = None
if args.local_experience:
    from installing.experience_policy import experience_scope, experience_blockers
    description = subprocess.run([str(root/'scripts/swift-local.sh'), 'package', 'describe', '--type', 'json'],
                                 cwd=root, capture_output=True, text=True, check=True, timeout=30)
    scope = experience_scope(root, json.loads(description.stdout))
inputs = [root / 'Package.swift', root / 'AGENTS.md', root / 'VERSION', root / 'BUILD_NUMBER', root / 'THIRD_PARTY_NOTICES.md', root / 'assets/brand/Traylet.icns']
inputs.extend(p for p in (root / 'Sources/TrayletApp/Resources').rglob('*') if p.is_file())
if scope:
    inputs.extend(root/name for name in scope['compiledSwiftFiles'])
directories = ('scripts', 'Tests/TrayletToolingTests') if scope else ('Sources', 'Tests', 'scripts')
for directory in directories:
    inputs.extend(p for p in (root / directory).rglob('*') if p.is_file() and p.suffix in ('.swift', '.sh', '.py'))
logs = sorted({args.test_log.resolve()} | set(args.test_log.resolve().parent.glob('*.txt')))
evidence = sorted((app_path.parent / 'evidence').rglob('*.png'))
bundle = app_path / 'Contents'
binary = bundle / 'MacOS/Traylet'
newer_sources = [p for p in inputs if (p.suffix == '.swift') and p.stat().st_mtime_ns > binary.stat().st_mtime_ns]
if newer_sources:
    raise RuntimeError('Source/test files are newer than the packaged binary; rebuild, test and package before recording evidence.')
newer_test_inputs = [p for p in inputs if p.suffix == '.swift' and p.stat().st_mtime_ns > xml.stat().st_mtime_ns]
if newer_test_inputs:
    raise RuntimeError('Source/test inputs are newer than the test results; run the full suite before recording evidence.')
manifest = {
    'createdAtUTC': datetime.now(timezone.utc).isoformat(),
    'environment': {'macOS': '27.0.1 arm64', 'Swift': '6.4 CLT', 'SDK': '26.5', 'deploymentTarget': '15.0; older systems untested'},
    'testCountsFromTestcaseElements': counts,
    'swiftTestingSuiteCount': int(suite.group(2)) if suite else None,
    'sourceGeneration': 'v2',
    'deliveryEligible': False,
    'deliveryBlockers': ['Prototype browser rendering was explicitly denied; exported reference and visual comparison remain outstanding.',
                         'New real Vision/system-translation and foreground routes remain unverified; inspect docs/development/verification.md.'],
    'permissionEvidenceNote': 'Permission files may predate this candidate and never establish current user approval. See verification.md.',
    'permissionEvidenceModifiedAtUTC': {str(p.relative_to(root)): datetime.fromtimestamp(p.stat().st_mtime, timezone.utc).isoformat() for p in [root / '.build/direct-smoke.json', root / '.build/launch-services-smoke.json'] if p.exists()},
    'permissionContexts': {name: json.loads(path.read_text()) if path.exists() else None for name, path in {
        'directProcess': root / '.build/direct-smoke.json',
        'launchServices': root / '.build/launch-services-smoke.json',
    }.items()},
    'files': {str(p.relative_to(root)): digest(p) for p in sorted(set(inputs))},
    'applicationPath': str(app_path.relative_to(root)),
    'binarySHA256': digest(binary),
    'infoPlistSHA256': digest(bundle / 'Info.plist'),
    'candidateNativeReports': {str(p.relative_to(root)): digest(p) for p in sorted((app_path.parent / 'evidence').glob('*report.json'))},
    'candidateNativeReportSHA256': digest(app_path.parent / 'evidence/shortcut-native-report.json') if (app_path.parent / 'evidence/shortcut-native-report.json').exists() else None,
    'xunitSHA256': digest(xml),
    'testResultsPath': str(xml.relative_to(root)),
    'testLogPath': str(args.test_log.resolve().relative_to(root)),
    'logs': {str(p.relative_to(root)): digest(p) for p in logs},
    'images': {str(p.relative_to(root)): {'sha256': digest(p), 'modifiedAtUTC': datetime.fromtimestamp(p.stat().st_mtime, timezone.utc).isoformat()} for p in evidence},
    'limits': ['Counts include opt-in skips; no real system translation or AI-provider claim.',
               'Native evidence uses synthetic fixtures and existing permissions.',
               'Old logs remain historical; docs/development/verification.md identifies final acceptance logs.'],
}
if scope:
    reports = [json.loads((root/name).read_text()) for name in manifest['candidateNativeReports']]
    blockers = experience_blockers(counts, reports, manifest['binarySHA256'])
    tooling_path = args.test_log.resolve().parent/'tooling.txt'
    tooling_text = tooling_path.read_text() if tooling_path.is_file() else ''
    tooling = re.search(r'Ran (\d+) tests? in .*?\n\s*\nOK\s*$', tooling_text, re.DOTALL)
    if tooling is None: blockers.append('Missing completed passing tooling regression.')
    if any('Scrolling' in c.get('classname', '') for c in cases):
        blockers.append('Deferred scrolling tests unexpectedly appear in experience results.')
    manifest.update(scope)
    manifest.update({'releaseKind': 'localExperienceStage11', 'fullProductComplete': False,
                     'deliveryEligible': not blockers, 'deliveryBlockers': blockers,
                     'toolingTestsPassed': int(tooling.group(1)) if tooling else None,
                     'explicitlyNotRun': ['EditingColorWellTests.activationRaisesPanelAfterAppKitAndRestoresState',
                                          'EditingColorWellTests.visiblePanelIsPreservedOnRelease'],
                     'knownLimitations': ['Scrolling implementation and its red test are preserved outside the compiled experience scope.',
                                          'Prototype reference rendering remains denied; this is a local trial of completed features.',
                                          'Real system permissions, IME/VoiceOver, multi-display and live translation/AI results remain separate user validation.',
                                          'No notarization or Gatekeeper override is implied by local signature integrity.']})
target = args.output
if not target.resolve().is_relative_to((root / 'build').resolve()):
    raise RuntimeError('Manifest output must remain inside this project build directory.')
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print(f'{target}: {counts}; {len(inputs)} inputs; {len(evidence)} images')
