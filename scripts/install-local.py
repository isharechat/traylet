#!/usr/bin/env python3
"""Install only a verified local Traylet release at its single user-facing location."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET
from installing.install_core import TARGET, IDENTIFIER, digest, info, replace_installed

ROOT = Path(__file__).resolve().parent.parent
STATE = ROOT/'build/install'

def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, timeout=30, capture_output=True, text=True, **kwargs)

def copy_bundle(source, destination):
    # ditto preserves bundle attributes, including quarantine; no security attributes are cleared.
    run(['/usr/bin/ditto', source, destination])

def project_file(name):
    value = (ROOT/name).resolve()
    if not value.is_relative_to(ROOT): raise RuntimeError('验证文件路径超出项目。')
    return value

def verify_bundle(app, manifest):
    if app.is_symlink() or not app.is_dir(): raise RuntimeError('候选App无效或为符号链接。')
    metadata = info(app)
    if metadata.get('CFBundleIdentifier') != IDENTIFIER or metadata.get('CFBundleExecutable') != 'Traylet':
        raise RuntimeError('候选应用身份不匹配。')
    if digest(app/'Contents/MacOS/Traylet') != manifest['binarySHA256'] or digest(app/'Contents/Info.plist') != manifest['infoPlistSHA256']:
        raise RuntimeError('候选App与已验manifest哈希不符，未安装。')
    run(['/usr/bin/codesign','--verify','--deep','--strict',app])

def verify_evidence(manifest, resolve):
    if manifest.get('deliveryEligible') is False:
        raise RuntimeError('该候选仍有明确放行阻塞，已保留安装版：' + '; '.join(manifest.get('deliveryBlockers', [])))
    counts=manifest.get('testCountsFromTestcaseElements',{})
    if counts.get('failed') != 0 or not isinstance(counts.get('successful'),int) or counts['successful']<=0:
        raise RuntimeError('没有已通过的测试证明，未安装。')
    xml=resolve(manifest['testResultsPath'])
    if digest(xml)!=manifest['xunitSHA256']: raise RuntimeError('测试XML哈希不符。')
    cases=ET.parse(xml).getroot().findall('.//testcase')
    actual={'total':len(cases),'successful':0,'skipped':0,'failed':0}
    for c in cases:
        kind='skipped' if c.find('skipped') is not None else 'failed' if c.find('failure') is not None or c.find('error') is not None else 'successful'
        actual[kind]+=1
    if actual!=counts: raise RuntimeError('测试统计不一致，未安装。')
    reports=manifest.get('candidateNativeReports',{})
    if not reports: raise RuntimeError('缺少同包原生验收报告，未自动放行。')
    for name,expected in reports.items():
        path=resolve(name)
        if digest(path)!=expected: raise RuntimeError('原生验收报告哈希不符。')
        report=json.loads(path.read_text())
        if report.get('passed') is not True or report.get('binarySHA256')!=manifest['binarySHA256']:
            raise RuntimeError('原生验收报告不属于该候选App，未安装。')

def prepare_release(manifest_path):
    manifest_path=manifest_path.resolve()
    if not manifest_path.is_relative_to(ROOT/'build'): raise RuntimeError('manifest须位于项目build内。')
    manifest=json.loads(manifest_path.read_text())
    source=project_file(manifest['applicationPath'])
    if not source.is_relative_to(ROOT/'build'): raise RuntimeError('候选须位于项目build内。')
    verify_bundle(source,manifest);verify_evidence(manifest,project_file)
    version=info(source).get('CFBundleShortVersionString','unknown')
    safe=re.sub(r'[^A-Za-z0-9._-]','_',str(version))
    release=STATE/'releases'/(safe+'-'+manifest['binarySHA256'][:12]+'-'+digest(manifest_path)[:10])
    if release.exists(): return load_release(release)
    assembling=release.parent/(release.name+'.assembling-'+uuid.uuid4().hex)
    assembling.mkdir(parents=True)
    try:
        copy_bundle(source,assembling/'Traylet.app')
        shutil.copy2(manifest_path,assembling/'manifest.json')
        names={manifest['testResultsPath']}|set(manifest['candidateNativeReports'])
        references={}
        for index,name in enumerate(sorted(names)):
            target=Path('evidence')/(str(index)+'-'+Path(name).name)
            (assembling/target).parent.mkdir(exist_ok=True)
            shutil.copy2(project_file(name),assembling/target);references[name]=str(target)
        (assembling/'release.json').write_text(json.dumps({'manifestSHA256':digest(manifest_path),'references':references,'originalManifest':str(manifest_path.relative_to(ROOT))},indent=2))
        load_release(assembling)
        assembling.rename(release)
    finally:
        if assembling.exists(): shutil.rmtree(assembling)
    return load_release(release)

def load_release(release):
    release=Path(release).resolve()
    if not release.is_relative_to(STATE/'releases'): raise RuntimeError('无效暂存目录。')
    receipt=json.loads((release/'release.json').read_text())
    manifest_path=release/'manifest.json'
    if digest(manifest_path)!=receipt['manifestSHA256']: raise RuntimeError('暂存manifest已变化。')
    manifest=json.loads(manifest_path.read_text());app=release/'Traylet.app'
    def resolve(name):
        path=(release/receipt['references'][name]).resolve()
        if not path.is_relative_to(release): raise RuntimeError('暂存验证路径无效。')
        return path
    verify_bundle(app,manifest);verify_evidence(manifest,resolve)
    return release,app,manifest

def runtime_helper():
    source=ROOT/'scripts/installing/runtime_apps.swift';binary=ROOT/'.build/runtime/traylet-running-apps'
    if not binary.exists() or binary.stat().st_mtime_ns<source.stat().st_mtime_ns:
        binary.parent.mkdir(parents=True,exist_ok=True)
        sdk=Path(os.environ.get('TRAYLET_SDK_PATH','/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk'))
        architecture=os.uname().machine
        run(['/usr/bin/xcrun','swiftc','-sdk',sdk,'-target',architecture+'-apple-macosx15.0',
             '-module-cache-path',ROOT/'.build/cache/clang',source,'-o',binary])
    return binary

def inventory():
    result=run([runtime_helper()])
    return json.loads(result.stdout)

def write_json(path,value):
    temp=path.with_name(path.name+'.tmp-'+uuid.uuid4().hex)
    temp.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n');os.replace(temp,path)

def open_installed():
    current=inventory()
    if not current.get('available'): return {'status':'not_opened_inventory_unknown'}
    if current['apps']: return {'status':'not_opened_existing_instance','runningApps':current['apps']}
    request=run(['/usr/bin/open',TARGET])
    for _ in range(10):
        observed=inventory()
        if observed.get('apps'):
            correct=[r for r in observed['apps'] if Path(r['bundlePath']).resolve()==TARGET.resolve()]
            return {'status':'opened' if len(correct)==1 and len(observed['apps'])==1 else 'launch_path_uncertain','runningApps':observed['apps']}
        time.sleep(0.3)
    return {'status':'open_requested_not_confirmed'}

def main():
    parser=argparse.ArgumentParser(description='验证后更新固定 /Applications/Traylet.app；不退出运行实例。')
    parser.add_argument('--manifest',type=Path,help='仅开发时指定已验候选manifest；默认复用最后已验暂存版')
    parser.add_argument('--open',action='store_true',help='仅在没有任何Traylet实例时正常打开固定安装版')
    parser.add_argument('--confirmed-exit-at',help='仅在用户刚明确保存并退出时传入带时区ISO时间；15分钟内、仅本次安装，已知运行实例仍阻止更新')
    args=parser.parse_args()
    STATE.mkdir(parents=True,exist_ok=True)
    with open(STATE/'installer.lock','a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        if args.manifest:
            release,source,manifest=prepare_release(args.manifest)
            write_json(STATE/'latest-verified.json',{'release':str(release.relative_to(ROOT))})
        else:
            pointer=json.loads((STATE/'latest-verified.json').read_text())
            release,source,manifest=load_release(project_file(pointer['release']))
        observations=[]
        def observed_inventory():
            current=inventory();observations.append(current);return current
        try:
            result=replace_installed(source,TARGET,inventory=observed_inventory,validate=lambda p:verify_bundle(p,manifest),copy_bundle=copy_bundle,confirmed_exit_at=args.confirmed_exit_at)
        except Exception as error:
            result={'status':'not_installed','target':str(TARGET),'reason':str(error),'stagedRelease':str(release),'noProcessTerminated':True,'runtimeObservations':observations,'userConfirmedExitAt':args.confirmed_exit_at}
            write_json(STATE/'last-result.json',result);print(json.dumps(result,ensure_ascii=False,indent=2));return 1
        result.update({'version':info(source)['CFBundleShortVersionString'],'build':info(source)['CFBundleVersion'],
                       'binarySHA256':manifest['binarySHA256'],'stagedRelease':str(release),'manifestSHA256':digest(release/'manifest.json'),'noProcessTerminated':True,
                       'runtimeObservations':observations,'userConfirmedExitAt':args.confirmed_exit_at})
        if any(r.get('available') is not True for r in observations):
            result['mayLaunch']=False
            result['runtimeStatus']='unknown; installation based on explicit user exit confirmation'
        if args.open and result['status'] in ['installed','already_installed']:
            try: result['launch']=open_installed()
            except Exception as error: result['launch']={'status':'not_opened','reason':str(error)}
        if result['status']=='staged_running': result['nextStep']='已暂存。请保存编辑并从Traylet菜单退出，再运行 scripts/install-local.sh --open；仍只打开 /Applications/Traylet.app。'
        elif result.get('runningApps'):
            if any(Path(a.get('bundlePath','')).resolve()==TARGET.resolve() for a in result['runningApps']):
                result['nextStep']='固定位置已是该版本；现有实例保留，未重复启动。需重开时请先保存退出。'
            else: result['nextStep']='固定安装版已更新；其他路径实例仍保留。请保存退出旧实例，再从 /Applications/Traylet.app 打开。'
        write_json(STATE/'last-result.json',result);print(json.dumps(result,ensure_ascii=False,indent=2))
        return 75 if result['status']=='staged_running' else 0

if __name__=='__main__':
    try: sys.exit(main())
    except Exception as error:
        print(json.dumps({'status':'blocked','target':str(TARGET),'reason':str(error),'noProcessTerminated':True},ensure_ascii=False,indent=2));sys.exit(1)
