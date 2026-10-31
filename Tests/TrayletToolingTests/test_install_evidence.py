import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPTS=Path(__file__).resolve().parents[2]/'scripts'
sys.path.insert(0,str(SCRIPTS))
spec=importlib.util.spec_from_file_location('traylet_local_installer',SCRIPTS/'install-local.py')
installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)

class InstallEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='traylet-install-evidence-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.xml=self.root/'tests.xml';self.xml.write_text('<testsuites><testsuite><testcase name="passed"/><testcase name="skipped"><skipped/></testcase></testsuite></testsuites>')
        self.report=self.root/'model-engine-native-report.json';self.report.write_text(json.dumps({'passed':True,'binarySHA256':'fixture-binary'}))
        self.manifest={'binarySHA256':'fixture-binary','xunitSHA256':installer.digest(self.xml),'testResultsPath':'tests.xml',
            'testCountsFromTestcaseElements':{'total':2,'successful':1,'skipped':1,'failed':0},
            'candidateNativeReports':{'model-engine-native-report.json':installer.digest(self.report)}}
    def verify(self): installer.verify_evidence(self.manifest,lambda name:self.root/name)
    def test_matching_passed_evidence_is_accepted_with_truthful_skip_count(self): self.verify()
    def test_missing_native_evidence_cannot_be_automatically_released(self):
        self.manifest['candidateNativeReports']={}
        with self.assertRaisesRegex(RuntimeError,'缺少'): self.verify()
    def test_native_evidence_for_different_binary_is_rejected(self):
        self.report.write_text(json.dumps({'passed':True,'binarySHA256':'OTHER'}))
        self.manifest['candidateNativeReports'][self.report.name]=installer.digest(self.report)
        with self.assertRaisesRegex(RuntimeError,'不属于'): self.verify()
    def test_changed_report_bytes_are_rejected(self):
        self.report.write_text('{"passed":true,"changed":true}')
        with self.assertRaisesRegex(RuntimeError,'哈希'): self.verify()
    def test_changed_test_xml_is_rejected(self):
        self.xml.write_text('<testsuites/>')
        with self.assertRaisesRegex(RuntimeError,'哈希'): self.verify()
    def test_xml_failure_is_not_hidden_by_false_passing_manifest(self):
        self.xml.write_text('<testsuites><testsuite><testcase name="failed"><failure/></testcase></testsuite></testsuites>')
        self.manifest['xunitSHA256']=installer.digest(self.xml)
        with self.assertRaisesRegex(RuntimeError,'统计'): self.verify()
