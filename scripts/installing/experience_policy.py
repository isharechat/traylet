"""Explicit local-experience scope; never treats deferred development files as tested."""
from pathlib import Path
import hashlib


def experience_scope(root, description):
    root = Path(root).resolve()
    expected_targets = {'TrayletApp': 'Sources/TrayletApp', 'TrayletCore': 'Sources/TrayletCore',
                        'TrayletAppTests': 'Tests/TrayletAppTests'}
    targets = description.get('targets', [])
    if len(targets) != 3 or {t.get('name') for t in targets} != set(expected_targets):
        raise RuntimeError('Unexpected experience target set.')
    compiled = set()
    for target in targets:
        if target.get('path') != expected_targets[target['name']]:
            raise RuntimeError('Unexpected target source directory.')
        for name in target.get('sources', []):
            path = (root/target['path']/name).resolve()
            if not path.is_relative_to(root/target['path']) or not path.is_file() or path.suffix != '.swift':
                raise RuntimeError('Invalid compiled source path.')
            compiled.add(path)
    all_sources = {p.resolve() for directory in ('Sources', 'Tests/TrayletAppTests')
                   for p in (root/directory).rglob('*.swift')}
    deferred_dirs = [root/'Sources/TrayletApp/Capture/Scrolling', root/'Tests/TrayletAppTests/Scrolling']
    deferred = {p for p in all_sources if any(p.is_relative_to(d) for d in deferred_dirs)}
    if not deferred or compiled != all_sources - deferred:
        raise RuntimeError('Compiled scope must contain every completed source and exclude only deferred scrolling.')
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    return {'compiledSwiftFiles': {str(p.relative_to(root)): digest(p) for p in sorted(compiled)},
            'excludedDevelopmentFiles': {str(p.relative_to(root)): digest(p) for p in sorted(deferred)}}


def experience_blockers(counts, reports, binary_sha):
    blockers = []
    if counts.get('failed') != 0 or counts.get('successful', 0) <= 0:
        blockers.append('Completed experience scope lacks passing tests.')
    if not reports:
        blockers.append('Missing same-binary offscreen evidence.')
    for report in reports:
        if report.get('passed') is not True or report.get('scope') != 'syntheticOffscreen' or report.get('binarySHA256') != binary_sha:
            blockers.append('Native evidence is failed, wrong-scope or belongs to another binary.')
    return blockers
