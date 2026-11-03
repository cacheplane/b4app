"""Checks fixture durability before publishing a permission event; no network or real runtime."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


class FixtureDurabilityTests(unittest.TestCase):
    def test_permission_is_durable_before_its_event_is_visible(self):
        path = Path(__file__).resolve().parents[3] / 'Tests/B4AdapterTests/Fixtures/fake-b4.py'
        spec = importlib.util.spec_from_file_location('fake_b4_durability', path)
        fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture)
        thread = dict(thread_id='thread', turns=[], messages=[], pending=[], status='busy',
                      created_at=fixture.now(), updated_at=fixture.now(), metadata={})
        fixture.STATE = {'threads': {'thread': thread}, 'counter': 0}
        fixture.LIVE = {}
        with tempfile.TemporaryDirectory() as directory:
            fixture.STATE_FILE = str(Path(directory) / 'state.json')
            run = fixture.Run('thread', 'please approve')
            observed = []
            emit = run.emit
            def record(event, data):
                if event == 'interrupt':
                    observed.append(json.loads(Path(fixture.STATE_FILE).read_text())['threads']['thread'])
                emit(event, data)
            run.emit = record
            fixture.execute(run)
        self.assertEqual(len(observed), 1)
        self.assertEqual(observed[0]['status'], 'interrupted')
        self.assertEqual(len(observed[0]['pending']), 1)
        self.assertEqual(observed[0]['turns'][0]['status'], 'awaiting')

class FixtureBindTests(unittest.TestCase):
    def test_both_entry_points_bind_without_reverse_dns(self):
        import contextlib
        import http.server
        import io
        import socketserver
        import sys
        from unittest import mock

        root = Path(__file__).resolve().parents[3] / 'Tests/B4AdapterTests/Fixtures'
        spec = importlib.util.spec_from_file_location('fixture_bind_test', root / 'fake-b4.py')
        fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture)
        fixture.STATE_FILE = None
        spec = importlib.util.spec_from_file_location('fixture_cli_bind_test', root / 'fake-b4-cli.py')
        cli = importlib.util.module_from_spec(spec)
        with mock.patch.object(sys, 'path', sys.path.copy()):
            spec.loader.exec_module(cli)
        for entry in ['standalone', 'managed']:
            with self.subTest(entry=entry), \
                 mock.patch('socket.getfqdn', side_effect=AssertionError('unexpected reverse DNS')), \
                 mock.patch.object(socketserver.TCPServer, 'server_bind'), \
                 mock.patch.object(socketserver.TCPServer, 'server_activate'), \
                 mock.patch.object(http.server.ThreadingHTTPServer, 'serve_forever', side_effect=KeyboardInterrupt), \
                 mock.patch.dict(sys.modules, {'fake_b4': fixture}), \
                 mock.patch.object(sys, 'argv', ['fake-b4', '--port', '0']), \
                 contextlib.redirect_stdout(io.StringIO()):
                # Only the OS bind/listen are stubbed. The actual entry point and stdlib/custom
                # server initialization run, so either entry point regressing to DNS fails here.
                if entry == 'standalone':
                    fixture.main()
                else:
                    self.assertEqual(cli.serve(0, 'ready at %d'), 0)


if __name__ == '__main__':
    unittest.main()
