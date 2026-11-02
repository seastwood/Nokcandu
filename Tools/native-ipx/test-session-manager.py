#!/usr/bin/env python3
"""Exercise session lifetime/concurrency without root or BPF/device changes.
Build access.c with NOK_IPX_TEST; that build has no device ownership operations.
"""
import os,pathlib,subprocess,tempfile,time,shutil,sys
helper=pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='nok-ipx-manager-test-') as temporary:
    root=pathlib.Path(temporary);env=dict(os.environ,NOK_IPX_TEST_HOME=temporary)
    def run(*args,check=True):
        return subprocess.run([str(helper),*map(str,args)],env=env,text=True,capture_output=True,check=check,timeout=8)
    assert run('--test-identity',1,0).returncode == 0, 'Root manager identity must be readable without task privileges'
    first=subprocess.Popen(['/bin/sleep','60']);second=subprocess.Popen(['/bin/sleep','60'])
    stage=root/'stage';stage.mkdir(mode=0o700);shutil.copy2(helper,stage/'native-ipx-access')
    try:
        one=run('--register',first.pid).stdout.strip();two=run('--register',second.pid).stdout.strip()
        assert one.startswith('session.') and two.startswith('session.')
        assert run('--check',check=False).returncode!=0
        started=run('--enable',os.getuid(),stage);assert 'ready' in started.stdout,started
        assert run('--check').returncode==0
        first.terminate();first.wait();time.sleep(1.5)
        assert run('--check').returncode==0,'Second game must retain access after first closes'
        assert stage.exists()
        second.terminate();second.wait()
        for _ in range(40):
            if run('--check',check=False).returncode!=0:break
            time.sleep(.1)
        assert run('--check',check=False).returncode!=0
        assert not stage.exists(),'Session manager should remove protected staging'
        assert not (root/'manager.state').exists()
        # A stale PID/start identity and a symlink must not prolong access.
        rogue=root/'sessions'/'session.forged';rogue.write_text(f'NOKIPX2 {os.getpid()} 0 0\n');rogue.chmod(0o600)
        (root/'sessions'/'session.link').symlink_to(rogue)
        stage.mkdir(mode=0o700);shutil.copy2(helper,stage/'native-ipx-access')
        assert run('--enable',os.getuid(),stage,check=False).returncode!=0
        assert 'no longer active' in run('--enable',os.getuid(),stage,check=False).stderr
        print('Two-game session lifetime, PID identity, symlink rejection and cleanup passed. No root/BPF changes.')
    finally:
        for child in (first,second):
            if child.poll() is None:child.terminate();child.wait()
