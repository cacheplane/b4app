"""Both fake B4 startup paths must bind without a hostname lookup."""
import contextlib
import http.server
import importlib.util
import io
from pathlib import Path
import socket
import sys
import unittest
from unittest import mock


class FixtureBindTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[2] / 'Tests/B4AdapterTests/Fixtures'
        spec = importlib.util.spec_from_file_location('fixture_bind_test', root / 'fake-b4.py')
        self.fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.fixture)
        self.fixture.STATE_FILE = None
        spec = importlib.util.spec_from_file_location('fixture_cli_bind_test', root / 'fake-b4-cli.py')
        self.cli = importlib.util.module_from_spec(spec)
        with mock.patch.object(sys, 'path', sys.path.copy()):
            spec.loader.exec_module(self.cli)

    def test_both_entry_points_reach_readiness_without_reverse_dns(self):
        for entry in ['standalone', 'managed']:
            output = io.StringIO()
            with self.subTest(entry=entry), \
                 mock.patch('socket.getfqdn', side_effect=AssertionError('unexpected reverse DNS')), \
                 mock.patch.object(http.server.ThreadingHTTPServer, 'serve_forever', side_effect=KeyboardInterrupt), \
                 mock.patch.dict(sys.modules, {'fake_b4': self.fixture}), \
                 mock.patch.object(sys, 'argv', ['fake-b4', '--port', '0']), \
                 contextlib.redirect_stdout(output):
                # Real OS bind/listen and real entry-point initialization; only stop the loop.
                if entry == 'standalone':
                    self.fixture.main()
                else:
                    self.assertEqual(self.cli.serve(0, 'ready at %d'), 0)
                self.assertTrue(output.getvalue().strip())

    def test_occupied_port_still_fails_before_readiness(self):
        with socket.socket() as occupied:
            occupied.bind(('127.0.0.1', 0))
            occupied.listen()
            port = occupied.getsockname()[1]
            for entry in ['standalone', 'managed']:
                output = io.StringIO()
                with self.subTest(entry=entry), \
                     mock.patch.dict(sys.modules, {'fake_b4': self.fixture}), \
                     mock.patch.object(sys, 'argv', ['fake-b4', '--port', str(port)]), \
                     contextlib.redirect_stdout(output):
                    with self.assertRaises(OSError):
                        if entry == 'standalone':
                            self.fixture.main()
                        else:
                            self.cli.serve(port, 'ready at %d')
                    self.assertEqual(output.getvalue(), '')


if __name__ == '__main__':
    unittest.main()
