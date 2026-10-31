#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
run_id=$(date -u +%Y%m%dT%H%M%SZ)
run_dir="$PWD/build/run-logs/v2-$run_id"
candidate="${TRAYLET_CANDIDATE_DIR:-$PWD/build/candidate-v2}"
mkdir -p "$run_dir" "$candidate"
mkdir -p "$run_dir/test-images"
if [[ "${TRAYLET_LOCAL_EXPERIENCE:-}" != "" && "${TRAYLET_LOCAL_EXPERIENCE:-}" != "1" ]]; then
  print -u2 "TRAYLET_LOCAL_EXPERIENCE must be empty or1"; exit 2
fi
python3 - "$run_dir" <<'PY'
from pathlib import Path
import json,hashlib,sys
paths=[Path('Package.swift'),Path('AGENTS.md'),Path('VERSION'),Path('BUILD_NUMBER'),Path('THIRD_PARTY_NOTICES.md')]+[p for d in ('Sources','Tests','scripts') for p in Path(d).rglob('*') if p.is_file() and p.suffix in ('.swift','.py','.sh')]
paths += [Path('assets/brand/Traylet.icns')] + [p for p in Path('Sources/TrayletApp/Resources').rglob('*') if p.is_file()]
(Path(sys.argv[1])/'input-hashes.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},sort_keys=True))
PY
# All opt-ins below use synthetic/private fixtures. Visible system color-panel tests stay outside this run.
export TRAYLET_ICON_SNAPSHOT="$run_dir/test-images/icons.png"
export TRAYLET_SETTINGS_SURFACE_DIR="$run_dir/test-images/settings-surfaces"
export TRAYLET_V2_NATIVE_EVIDENCE_TEST_DIR="$run_dir/test-images/native"
export TRAYLET_REFERENCE_PERF_DIR="$run_dir/performance"
export TRAYLET_IMPORTED_IMAGE_EVIDENCE_DIR="$run_dir/test-images/imported"
export TRAYLET_HIGHLIGHTER_EVIDENCE_DIR="$run_dir/test-images/highlighter"
export TRAYLET_HISTORY_OCR_EVIDENCE_DIR="$run_dir/test-images/history-ocr"
export TRAYLET_CLIPBOARD_CONTROLS_EVIDENCE_DIR="$run_dir/test-images/clipboard-controls"
export TRAYLET_PRECISE_EDITING_EVIDENCE_DIR="$run_dir/test-images/precise-editing"
export TRAYLET_OBJECT_EDITING_EVIDENCE_DIR="$run_dir/test-images/object-editing"
export TRAYLET_TEXT_OBJECT_EVIDENCE_DIR="$run_dir/test-images/text-object"
export TRAYLET_REWRITE_TRANSLATION_AX_PROBE=1 TRAYLET_PERF=1 TRAYLET_REFERENCE_PERF=1 TRAYLET_REWRITE_VISION_TEST=1
TRAYLET_CLIPBOARD_SNAPSHOT_DIR="$run_dir/test-images/clipboard" \
TRAYLET_SETTINGS_SNAPSHOT_DIR="$run_dir/test-images/settings" \
TRAYLET_REWRITE_TRANSLATION_EVIDENCE_DIR="$run_dir/test-images/translation" \
scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests --xunit-output "$run_dir/tests.xml" > "$run_dir/tests.txt" 2>&1
python3 -m unittest discover -s Tests/TrayletToolingTests > "$run_dir/tooling.txt" 2>&1
TRAYLET_APP_OUTPUT="$candidate/Traylet.app" scripts/package-local.sh > "$run_dir/package.txt" 2>&1
python3 - "$candidate" "$run_dir" <<'PY'
from pathlib import Path
import subprocess, json, hashlib, sys, uuid
candidate=Path(sys.argv[1]); logs=Path(sys.argv[2])
binary=candidate/'Traylet.app/Contents/MacOS/Traylet'
digest=lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
before=digest(binary)
# New empty evidence output avoids mixed generations; prior evidence is preserved.
output=candidate/('evidence-new-'+uuid.uuid4().hex)
with (logs/'native-evidence.txt').open('w') as log:
    subprocess.run([str(binary.resolve()),'--v2-native-evidence',str(output.resolve())],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=120)
if digest(binary)!=before: raise RuntimeError('Binary changed during evidence generation.')
report=output/'evidence-report.json'
data=json.loads(report.read_text())
if data.get('passed') is not True or data.get('scope')!='syntheticOffscreen': raise RuntimeError('Native evidence did not pass.')
data['binarySHA256']=before
report.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
previous=candidate/'evidence'
if previous.exists(): previous.rename(candidate/('evidence-previous-'+uuid.uuid4().hex))
output.rename(previous)
inputs=json.loads((logs/'input-hashes.json').read_text())
paths=[Path('Package.swift'),Path('AGENTS.md'),Path('VERSION'),Path('BUILD_NUMBER'),Path('THIRD_PARTY_NOTICES.md')]+[p for d in ('Sources','Tests','scripts') for p in Path(d).rglob('*') if p.is_file() and p.suffix in ('.swift','.py','.sh')]
paths += [Path('assets/brand/Traylet.icns')] + [p for p in Path('Sources/TrayletApp/Resources').rglob('*') if p.is_file()]
current={str(p):digest(p) for p in paths}
if current!=inputs: raise RuntimeError('Inputs changed during verification; no manifest will be written.')
PY
profile_arguments=()
if [[ "${TRAYLET_LOCAL_EXPERIENCE:-}" == "1" ]]; then profile_arguments+=(--local-experience); fi
python3 scripts/record-build-manifest.py "${profile_arguments[@]}" --app-path "$candidate/Traylet.app" \
 --output "$candidate/build-manifest.json" --test-results "$run_dir/tests.xml" --test-log "$run_dir/tests.txt"
print -r -- "V2 candidate checks recorded. Inspect deliveryEligible and blockers before installation."
