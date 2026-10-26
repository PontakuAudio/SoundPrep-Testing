import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('prepare', Path(__file__).parents[1] / 'worker/prepare.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class PrepareWorkerTests(unittest.TestCase):
    @unittest.skipIf(os.name == 'nt', 'POSIX process-group exit race')
    def test_owned_process_exit_during_signal_is_still_reaped(self):
        child = mock.Mock(pid=12345)
        child.poll.return_value = None
        with mock.patch.object(worker.os, 'killpg', side_effect=ProcessLookupError):
            worker.stop_owned(child)
        child.wait.assert_called_once_with(timeout=6)

    @unittest.skipIf(os.name == 'nt', 'POSIX process-group exit race')
    def test_owned_process_exit_during_kill_is_still_reaped(self):
        child = mock.Mock(pid=12345)
        child.poll.return_value = None
        child.wait.side_effect = [subprocess.TimeoutExpired('owned', 6), 0]
        with mock.patch.object(worker.os, 'killpg', side_effect=[None, ProcessLookupError]):
            worker.stop_owned(child)
        self.assertEqual(child.wait.call_args_list, [mock.call(timeout=6), mock.call(timeout=3)])

    def test_single_drop_job_finishes_without_parent_heartbeat_and_keeps_media_for_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'
            source.mkdir()
            plugin = root / 'worker.dll'
            plugin.write_bytes(b'fixture')
            owned = root / 'drop-job'
            owned.mkdir()
            (owned / 'media').mkdir()
            (owned / 'media' / 'render.wav').write_bytes(b'rendered')
            result = {'job_id': 'test', 'status': 'ready'}
            (owned / 'result.json').write_text(worker.json.dumps(result))
            config = dict(directory=str(owned), resource=str(source), executable='owned-worker',
                          worker_plugin=str(plugin), bootstrap=str(owned / 'start.lua'), timeout=5, single_job=True)
            with mock.patch.object(worker.subprocess, 'Popen') as launch, mock.patch.object(worker, 'stop_owned') as stop:
                launch.return_value.pid = os.getpid()
                with mock.patch.object(worker.os, 'setpriority', create=True):
                    self.assertEqual(worker.run(config), result)
                stop.assert_called_once_with(launch.return_value)
            self.assertTrue((owned / 'media' / 'render.wav').is_file())
            self.assertFalse((owned / 'heartbeat').exists())
            self.assertFalse((owned / 'host').exists())

    def test_resource_isolation_and_minimal_preferences(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'source'
            source.mkdir()
            (source / 'reaper.ini').write_text('[REAPER]\nlastproject=private.rpp\nloadlastproj=1\ndefpitchcfg=589824\nvstpath=/Plugins\nstartupaction=123\n')
            (source / 'Effects').mkdir()
            target = Path(directory) / 'owned'
            worker.resource_directory(source, target)
            text = (target / 'reaper.ini').read_text()
            self.assertIn('lastproject=\n', text)
            self.assertIn('loadlastproj=0', text)
            self.assertIn('vstpath=/Plugins', text)
            self.assertNotIn('startupaction', text)
            self.assertEqual((target / 'Effects').resolve(), (source / 'Effects').resolve())
            self.assertTrue((target / '.audition-macro-worker').is_file())
            worker.resource_directory(source, target)  # Owned directory is reusable.

    def test_refuses_user_resource_or_unowned_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            for target in (source, source / 'existing'):
                target.mkdir(exist_ok=True)
                with self.assertRaises(ValueError):
                    worker.resource_directory(source, target)

    def test_owned_process_is_reaped_without_touching_a_peer(self):
        argv = [sys.executable, '-c', 'import time; time.sleep(30)']
        child = subprocess.Popen(argv, start_new_session=os.name != 'nt')
        peer = subprocess.Popen(argv, start_new_session=os.name != 'nt')
        try:
            worker.stop_owned(child)
            self.assertIsNotNone(child.poll())
            self.assertIsNone(peer.poll())
            worker.stop_owned(child)  # Repeated cleanup is harmless.
        finally:
            worker.stop_owned(child)
            worker.stop_owned(peer)


if __name__ == '__main__':
    unittest.main()
