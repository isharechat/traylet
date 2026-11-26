"""Local macOS bundle replacement policy. No process termination or security-setting changes."""
from pathlib import Path
import ctypes
import hashlib
import os
import plistlib
import shutil
import uuid
from datetime import datetime, timezone

IDENTIFIER = 'local.traylet.app'
TARGET = Path('/Applications/Traylet.app')

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def info(app):
    return plistlib.loads((Path(app)/'Contents/Info.plist').read_bytes())

def atomic_rename(source, destination, *, swap=False):
    # Darwin public renamex_np: SWAP=2, EXCL=4. Both operands stay on the same volume.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 2 if swap else 4):
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))

def known_inventory(inventory, confirmed_exit_at=None):
    current = inventory()
    if confirmed_exit_at is not None:
        try:
            confirmed = datetime.fromisoformat(confirmed_exit_at.replace('Z', '+00:00'))
            if confirmed.tzinfo is None: raise ValueError('timezone required')
            age = (datetime.now(timezone.utc) - confirmed).total_seconds()
            if not 0 <= age <= 900: raise ValueError('expired or future')
        except (ValueError, TypeError):
            raise RuntimeError('用户退出确认无效或超过15分钟；请重新确认，未更新。')
    if current.get('available') is not True or not isinstance(current.get('apps'), list):
        # This is explicit, fresh user evidence for this invocation, never a fabricated inventory.
        # Any observed instance still wins. Unknown paths and malformed probes cannot be overridden.
        if confirmed_exit_at is not None and current.get('apps') == []:
            return []
        raise RuntimeError('无法确定运行状态；已暂存，未更新。请从正常桌面会话重试。')
    if any(not isinstance(row.get('bundlePath'), str) or not Path(row['bundlePath']).is_absolute() for row in current['apps']):
        raise RuntimeError('运行状态中的应用路径未知；未更新。')
    return current['apps']

def is_running(path, apps):
    path = Path(path).resolve()
    return any(row.get('bundlePath') and Path(row['bundlePath']).resolve() == path for row in apps)

def same_bundle(left, right):
    return digest(left/'Contents/MacOS/Traylet') == digest(right/'Contents/MacOS/Traylet') and digest(left/'Contents/Info.plist') == digest(right/'Contents/Info.plist')

def replace_installed(source, target=TARGET, backups=None, *, inventory, validate, copy_bundle=shutil.copytree, confirmed_exit_at=None):
    source, target = Path(source), Path(target)
    backups = Path(backups or target.parent/'.Traylet-backups')
    validate(source)
    apps = known_inventory(inventory, confirmed_exit_at)
    if target.is_symlink() or backups.is_symlink():
        raise RuntimeError('安装位置或备份位置是符号链接，未更改。')
    if target.exists():
        if info(target).get('CFBundleIdentifier') != IDENTIFIER:
            raise RuntimeError('固定位置存在其他应用，未覆盖。')
        if same_bundle(source, target):
            validate(target)
            return {'status':'already_installed','target':str(target),'backup':None,'runningApps':apps,'mayLaunch':not apps}
    if target.exists():
        old = info(target); new = info(source)
        def version_key(value):
            if not str(value).replace('.', '').isdigit(): raise RuntimeError('版本号无法安全比较，未更新。')
            return tuple(int(part) for part in str(value).split('.'))
        if (version_key(new.get('CFBundleShortVersionString', '')), version_key(new.get('CFBundleVersion', ''))) < (version_key(old.get('CFBundleShortVersionString', '')), version_key(old.get('CFBundleVersion', ''))):
            raise RuntimeError('固定位置已有较新版本，未自动降级。')
    if is_running(target, apps):
        return {'status':'staged_running','target':str(target),'backup':None,'runningApps':apps,'mayLaunch':False}
    target.parent.mkdir(parents=True, exist_ok=True)
    stage = target.parent/('.Traylet-stage-'+uuid.uuid4().hex+'.app')
    backup = None
    swapped = False
    try:
        copy_bundle(source, stage)
        validate(stage)
        # Recheck after the copy, immediately before committing. Never terminate a process.
        apps = known_inventory(inventory, confirmed_exit_at)
        if is_running(target, apps):
            return {'status':'staged_running','target':str(target),'backup':None,'runningApps':apps,'mayLaunch':False}
        if target.exists():
            if target.is_symlink() or info(target).get('CFBundleIdentifier') != IDENTIFIER:
                raise RuntimeError('安装位置在暂存期间变化，未覆盖其他应用。')
            backups.mkdir(parents=True, exist_ok=True)
            old_version = str(info(target).get('CFBundleShortVersionString','unknown'))
            safe_version = ''.join(c for c in old_version if c.isalnum() or c in '.-_')
            backup = backups/(safe_version+'-'+digest(target/'Contents/MacOS/Traylet')[:12]+'-'+uuid.uuid4().hex[:8]+'.app')
            atomic_rename(stage, target, swap=True)
            swapped = True
            try:
                validate(target)
                # Old bundle is now at stage; retain it atomically on the same volume.
                atomic_rename(stage, backup)
                swapped = False
            except BaseException:
                if stage.exists():
                    atomic_rename(stage, target, swap=True)
                    swapped = False
                raise
        else:
            atomic_rename(stage, target)
            try:
                validate(target)
            except BaseException:
                atomic_rename(target, stage)
                raise
        return {'status':'installed','target':str(target),'backup':str(backup) if backup else None,'runningApps':apps,'mayLaunch':not apps}
    finally:
        # A failed rollback keeps both bundles for diagnosis rather than deleting the recoverable old one.
        if stage.exists() and not swapped:
            shutil.rmtree(stage)
