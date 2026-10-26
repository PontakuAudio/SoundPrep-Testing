import importlib.util
import json
import math
from pathlib import Path
import shutil
import struct
import tempfile
import unittest
from unittest import mock
import wave

spec = importlib.util.spec_from_file_location("analyze", Path(__file__).parents[1] / "worker/analyze.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="AM Unicode 日本語 '")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.ffmpeg = shutil.which("ffmpeg")
        if not self.ffmpeg:
            self.skipTest("FFmpeg is not installed")

    def audio(self, duration=1, amplitude=.125, channels=1):
        path = self.root / "a file's 素材.wav"
        with wave.open(str(path), "wb") as wav:
            wav.setparams((channels, 2, 48000, 0, "NONE", "not compressed"))
            wav.writeframes(b"".join(struct.pack("<h", int(amplitude * 32767 * math.sin(2 * math.pi * 1000 * i / 48000))) * channels
                                     for i in range(round(duration * 48000))))
        return path

    def run_audio(self, path):
        stat = path.stat()
        request = {"identity": {"path": str(path), "size": stat.st_size, "mtime": int(stat.st_mtime)},
                   "ffmpeg": self.ffmpeg, "analyzer_key": "test", "timeout": 10}
        cancel = self.root / "cancel"
        return worker.analyze(request, cancel)

    def test_tone_dual_mono_matches_stereo(self):
        mono = self.run_audio(self.audio())
        stereo = self.run_audio(self.audio(channels=2))
        self.assertAlmostEqual(mono["max_momentary_lufs"], stereo["max_momentary_lufs"], delta=.02)
        self.assertAlmostEqual(mono["true_peak_dbtp"], -18.06, delta=.05)
        self.assertTrue(-19 < mono["max_momentary_lufs"] < -17)

    def test_short_effect_gets_a_complete_zero_padded_window(self):
        result = self.run_audio(self.audio(duration=.02))
        self.assertEqual(result["status"], "ready")
        self.assertTrue(math.isfinite(result["max_momentary_lufs"]))

    def test_silence_is_not_given_unbounded_gain(self):
        result = self.run_audio(self.audio(amplitude=0))
        self.assertEqual(result["status"], "silence")
        self.assertIsNone(result["max_momentary_lufs"])

    def test_stale_file_is_rejected(self):
        path = self.audio()
        with self.assertRaises(ValueError):
            worker.analyze({"identity": {"path": str(path), "size": 1, "mtime": 0}}, self.root / "cancel")


class WorkerCancellationTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.cancel = self.root / 'cancel'
        self.source = self.root / 'source.wav'
        self.source.write_bytes(b'fixture')
        stat = self.source.stat()
        self.request = {'identity': {'path': str(self.source), 'size': stat.st_size,
                                    'mtime': int(stat.st_mtime)},
                        'ffmpeg': 'ffmpeg', 'analyzer_key': 'test'}

    def test_cancelled_job_does_not_launch_probe_or_analysis(self):
        self.cancel.touch()
        info = mock.Mock(stdout=b'{"streams":[{"channels":1,"sample_rate":"48000","duration":"1"}]}')
        process = mock.Mock()
        process.poll.return_value = None
        with mock.patch.object(worker.subprocess, 'run', return_value=info) as probe, \
                mock.patch.object(worker.subprocess, 'Popen', return_value=process) as analyze:
            with self.assertRaises(InterruptedError):
                worker.analyze(self.request, self.cancel)
        probe.assert_not_called()
        analyze.assert_not_called()

    def test_cancellation_during_probe_does_not_launch_analysis(self):
        def probe(*args, **kwargs):
            self.cancel.touch()
            return mock.Mock(stdout=b'{"streams":[{"channels":1,"sample_rate":"48000","duration":"1"}]}')
        process = mock.Mock()
        process.poll.return_value = None
        with mock.patch.object(worker.subprocess, 'run', side_effect=probe), \
                mock.patch.object(worker.subprocess, 'Popen', return_value=process) as analyze:
            with self.assertRaises(InterruptedError):
                worker.analyze(self.request, self.cancel)
        analyze.assert_not_called()

    def test_running_analysis_is_terminated_and_reaped_on_cancel(self):
        process = mock.Mock()
        process.poll.return_value = None
        def launch(*args, **kwargs):
            self.cancel.touch()
            return process
        probe = mock.Mock(stdout=b'{"streams":[{"channels":1,"sample_rate":"48000","duration":"1"}]}')
        with mock.patch.object(worker.subprocess, 'run', return_value=probe), \
                mock.patch.object(worker.subprocess, 'Popen', side_effect=launch):
            with self.assertRaises(InterruptedError):
                worker.analyze(self.request, self.cancel)
        process.terminate.assert_called_once_with()
        process.wait.assert_called_once_with(timeout=2)

    def test_completed_analysis_cannot_publish_after_cancellation(self):
        process = mock.Mock(returncode=0)
        process.poll.return_value = 0
        def launch(*args, **kwargs):
            kwargs['stdout'].write(b'lavfi.r128.M=-18\nlavfi.r128.true_peak=0.125\n')
            self.cancel.touch()
            return process
        probe = mock.Mock(stdout=b'{"streams":[{"channels":1,"sample_rate":"48000","duration":"1"}]}')
        with mock.patch.object(worker.subprocess, 'run', return_value=probe), \
                mock.patch.object(worker.subprocess, 'Popen', side_effect=launch):
            with self.assertRaises(InterruptedError):
                worker.analyze(self.request, self.cancel)
        process.terminate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
