#!/usr/bin/env python3
"""Run real Git push/pull operations with fake Beads in temporary repositories."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class GitHooksTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rata-git-hooks-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.log = self.base / "bd.log"
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        fake_bd = bin_dir / "bd"
        fake_bd.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, subprocess, sys\n"
            "assert os.environ.get('RATA_BEADS_SYNC_ACTIVE') == '1'\n"
            "assert 'GIT_DIR' not in os.environ\n"
            "assert 'GIT_INDEX_FILE' not in os.environ\n"
            "with open(os.environ['RATA_TEST_LOG'], 'a') as f:\n"
            "    f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "if os.environ.get('RATA_TEST_RECURSE'):\n"
            "    subprocess.run([os.environ['RATA_TEST_RECURSE'], 'origin', 'unused'], check=True)\n"
            "sys.exit(int(os.environ.get('RATA_TEST_FAIL', '0')))\n"
        )
        fake_bd.chmod(0o755)
        self.fake_bd = fake_bd
        self.env = dict(os.environ)
        for name in list(self.env):
            if name.startswith(('GIT_', 'BD_', 'BEADS_', 'RATA_BEADS_')):
                del self.env[name]
        self.env.update(
            PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
            GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
            GIT_AUTHOR_NAME='Hook Test', GIT_AUTHOR_EMAIL='test@example.invalid',
            GIT_COMMITTER_NAME='Hook Test', GIT_COMMITTER_EMAIL='test@example.invalid',
            RATA_TEST_LOG=str(self.log),
            JUST_TEMPDIR=str(self.base),
        )
        self.origin = self.base / 'origin.git'
        self.a = self.base / 'a'
        self.b = self.base / 'b'
        self.git(self.base, 'init', '--bare', '--initial-branch=main', str(self.origin))
        self.git(self.base, 'clone', str(self.origin), str(self.a))
        self.commit(self.a, 'seed')
        self.git(self.a, 'push', '-u', 'origin', 'main')
        self.git(self.base, 'clone', str(self.origin), str(self.b))
        (self.a / '.beads').mkdir()
        (self.a / 'scripts').mkdir()
        shutil.copy2(ROOT / 'scripts/beads-git-sync.sh', self.a / 'scripts')
        self.git(self.a, 'config', 'core.hooksPath', str(ROOT / '.githooks'))

    def run_command(self, cwd, *args, check=True, env=None):
        result = subprocess.run(args, cwd=cwd, env=env or self.env,
                                text=True, capture_output=True)
        if check and result.returncode:
            self.fail(f'{args}: {result.stdout}\n{result.stderr}')
        return result

    def git(self, cwd, *args, **kwargs):
        return self.run_command(cwd, 'git', *args, **kwargs)

    def commit(self, repo, filename):
        (repo / filename).write_text(filename)
        self.git(repo, 'add', filename)
        self.git(repo, '-c', 'core.hooksPath=/dev/null', 'commit', '-m', filename)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_push_syncs_and_prevents_recursion(self):
        self.commit(self.a, 'push-change')
        self.env['RATA_TEST_RECURSE'] = str(ROOT / '.githooks/pre-push')
        self.git(self.a, 'push', 'origin', 'main')
        self.assertEqual(self.calls(), [['sync', '--remote', 'origin']])
        self.assertEqual(self.git(self.a, 'rev-parse', 'HEAD').stdout,
                         self.git(self.origin, 'rev-parse', 'main').stdout)

    def test_failed_sync_blocks_code_push(self):
        before = self.git(self.origin, 'rev-parse', 'main').stdout
        self.commit(self.a, 'blocked-change')
        self.env['RATA_TEST_FAIL'] = '2'
        result = self.git(self.a, 'push', 'origin', 'main', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('code push blocked', result.stderr)
        self.assertEqual(before, self.git(self.origin, 'rev-parse', 'main').stdout)

    def test_fast_forward_pull(self):
        self.commit(self.b, 'remote-change')
        self.git(self.b, 'push')
        self.git(self.a, 'pull', '--ff-only')
        self.assertEqual(self.calls(), [['dolt', 'pull', '--remote', 'origin']])

    def test_rebase_pull(self):
        self.commit(self.a, 'local-change')
        self.commit(self.b, 'remote-change')
        self.git(self.b, 'push')
        self.git(self.a, '-c', 'core.hooksPath=/dev/null', 'fetch')
        # The apply backend avoids invoking unrelated pre-commit checks.
        self.git(self.a, '-c', 'rebase.backend=apply', 'pull', '--rebase')
        self.assertEqual(self.calls(), [['dolt', 'pull', '--remote', 'origin']])

    def test_rebase_pull_with_fast_forward(self):
        self.commit(self.b, 'remote-change')
        self.git(self.b, 'push')
        self.git(self.a, 'pull', '--rebase')
        self.assertEqual(self.calls(), [['dolt', 'pull', '--remote', 'origin']])

    def test_failed_task_pull_reports_code_already_updated(self):
        self.commit(self.b, 'remote-change')
        self.git(self.b, 'push')
        self.env['RATA_TEST_FAIL'] = '1'
        result = self.git(self.a, 'pull', '--ff-only', check=False)
        self.assertIn('Code may already be updated', result.stderr)
        self.assertTrue((self.a / 'remote-change').exists())

    def test_just_pull_syncs_when_code_unchanged(self):
        self.run_command(self.a, 'just', '--justfile', str(ROOT / 'justfile'),
                         '--working-directory', str(self.a), 'pull', '--ff-only')
        self.assertEqual(self.calls(), [['dolt', 'pull', '--remote', 'origin']])

    def test_other_remote_is_not_synced(self):
        self.git(self.a, 'remote', 'add', 'other', str(self.origin))
        self.commit(self.a, 'other-change')
        self.git(self.a, 'push', 'other', 'main')
        self.assertEqual(self.calls(), [])

    def test_just_pull_does_not_double_sync(self):
        self.commit(self.b, 'remote-change')
        self.git(self.b, 'push')
        self.run_command(self.a, 'just', '--justfile', str(ROOT / 'justfile'),
                         '--working-directory', str(self.a), 'pull', '--ff-only')
        self.assertEqual(self.calls(), [['dolt', 'pull', '--remote', 'origin']])

    def test_git_hook_environment_does_not_leak_to_bd(self):
        self.env['GIT_DIR'] = str(self.a / '.git')
        self.env['GIT_INDEX_FILE'] = str(self.a / '.git/index')
        self.run_command(self.a, str(ROOT / '.githooks/pre-push'), 'origin', 'unused')
        self.assertEqual(self.calls(), [['sync', '--remote', 'origin']])

    def test_missing_bd_blocks_push(self):
        self.fake_bd.unlink()
        # Exclude any real bd using a PATH with only the hook's prerequisites.
        isolated_bin = self.base / 'isolated-bin'
        isolated_bin.mkdir()
        for command in ('bash', 'dirname', 'git'):
            (isolated_bin / command).symlink_to(shutil.which(command))
        self.env['PATH'] = str(isolated_bin)
        result = self.run_command(self.a, str(ROOT / '.githooks/pre-push'),
                                  'origin', 'unused', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('bd is required', result.stderr)

    def test_amend_does_not_pull_tasks(self):
        self.run_command(self.a, str(ROOT / '.githooks/post-rewrite'), 'amend')
        self.assertEqual(self.calls(), [])

    def test_missing_workspace_blocks_sync(self):
        (self.a / '.beads').rmdir()
        result = self.run_command(self.a, str(ROOT / '.githooks/pre-push'),
                                  'origin', 'unused', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('bd bootstrap', result.stderr)
        self.assertEqual(self.calls(), [])


if __name__ == '__main__':
    unittest.main()
