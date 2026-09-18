"""A scan must be visible while it runs, and land by itself when it ends.

Two defects sit behind this. A FileView can only be trusted for a file that
existed when it was constructed, so on a fresh install neither index file was
being watched and a finished scan never reached the panel — every first-time
user stayed at an empty library until they restarted the shell. And a scan of a
real library takes minutes (2 min 42 s measured over a tailnet) with nothing to
watch, so the only honest thing to show is counts that climb.

Run from the repo root:  python3 -m unittest discover -s tests
No Plex server and no token: the network is a fake and the state is a temp dir.
"""

import importlib.machinery
import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
HELPER = os.path.join(REPO, "bin", "plexmusic")


def load_helper():
    loader = importlib.machinery.SourceFileLoader("plexmusic_helper", HELPER)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def page(kind, rows, total, start=0):
    return {"MediaContainer": {"totalSize": total, "Metadata": [
        {"ratingKey": start + i, "title": "%s %d" % (kind, start + i),
         "grandparentTitle": "A", "parentTitle": "B"}
        for i in range(rows)]}}


class ProgressFileTests(unittest.TestCase):
    """`index` publishes its progress; `progress` reports it."""

    def setUp(self):
        self.pm = load_helper()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        data = os.path.join(self.tmp.name, "data")
        cfg = os.path.join(self.tmp.name, "config")
        self.pm.DATA_DIR = data
        self.pm.ARTISTS_FILE = os.path.join(data, "artists.json")
        self.pm.TRACKS_FILE = os.path.join(data, "tracks.json")
        self.pm.PROGRESS_FILE = os.path.join(data, "index-progress.json")
        self.pm.CONFIG_DIR = cfg
        self.pm.AUTH_FILE = os.path.join(cfg, "auth.json")
        self.pm.SETTINGS_FILE = os.path.join(cfg, "settings.json")
        self.pm.CACHE_DIR = os.path.join(self.tmp.name, "cache")
        self.pm.LOG_FILE = os.path.join(self.pm.CACHE_DIR, "plexmusic.log")
        self.pm.write_json(self.pm.AUTH_FILE, {"auth" + "Token": "fake"})
        self.pm.write_json(self.pm.SETTINGS_FILE,
                           {"baseUrl": "http://plex.example:32400",
                            "musicSection": "31"})
        self.seen = []

    def run_index(self, artist_pages=1, track_pages=2):
        """Run cmd_index against a fake server, recording every progress file
        state it publishes along the way."""
        calls = {"n": 0}
        real_write = self.pm.write_json

        def spy(path, data, mode=0o600):
            real_write(path, data, mode)
            if path == self.pm.PROGRESS_FILE:
                self.seen.append(dict(data))

        def fake_get(_self, path, params=None, **kw):
            params = params or {}
            if params.get("type") == 8:
                start = params.get("X-Plex-Container-Start", 0)
                total = artist_pages * 2
                rows = 2 if start < total else 0
                return page("artist", rows, total, start)
            if params.get("type") == 10:
                start = params.get("X-Plex-Container-Start", 0)
                total = track_pages * 3
                rows = 3 if start < total else 0
                return page("track", rows, total, start)
            return {"MediaContainer": {}}

        with mock.patch.object(self.pm, "write_json", spy), \
             mock.patch.object(self.pm.Plex, "resolve_base",
                               lambda s, force=False: "http://plex.example:32400"), \
             mock.patch.object(self.pm.Plex, "get", fake_get):
            out = io.StringIO()
            with redirect_stdout(out):
                self.pm.cmd_index(None)
        return json.loads(out.getvalue())

    def test_the_counts_climb_while_the_scan_runs(self):
        d = self.run_index(artist_pages=2, track_pages=3)
        self.assertTrue(d["ok"])
        stages = [s["stage"] for s in self.seen]
        self.assertEqual(stages[0], "starting")
        self.assertIn("artists", stages)
        self.assertIn("tracks", stages)
        self.assertEqual(stages[-1], "done")
        # The point of the whole thing: a number that goes up, more than once.
        tracks = [s["tracks"] for s in self.seen if s["stage"] == "tracks"]
        self.assertGreater(len(tracks), 1, "only one progress update")
        self.assertEqual(tracks, sorted(tracks))
        self.assertGreater(tracks[-1], tracks[0])
        # And a total to count towards, so the panel can say "n of m". The
        # first "tracks" state is published before the first page comes back,
        # so it has no total yet; every state after it must.
        totals = [s["trackTotal"] for s in self.seen
                  if s["stage"] == "tracks" and s["tracks"] > 0]
        self.assertTrue(totals and all(t == 9 for t in totals), totals)

    def test_the_final_state_says_done_with_the_real_counts(self):
        d = self.run_index(artist_pages=2, track_pages=3)
        final = self.pm.read_json(self.pm.PROGRESS_FILE, {})
        self.assertEqual(final["stage"], "done")
        self.assertEqual(final["artists"], d["artistCount"])
        self.assertEqual(final["tracks"], d["trackCount"])
        self.assertIn("finishedAt", final)

    def test_progress_reports_a_finished_scan_as_not_running(self):
        self.run_index()
        out = io.StringIO()
        with redirect_stdout(out):
            self.pm.cmd_progress(None)
        d = json.loads(out.getvalue())
        self.assertFalse(d["running"])
        self.assertEqual(d["stage"], "done")

    def test_progress_is_harmless_before_anything_has_run(self):
        out = io.StringIO()
        with redirect_stdout(out):
            self.pm.cmd_progress(None)
        d = json.loads(out.getvalue())
        self.assertTrue(d["ok"])
        self.assertFalse(d["running"])
        self.assertEqual(d["stage"], "none")
        self.assertEqual(d["artists"], 0)

    def test_the_progress_file_is_owner_only(self):
        self.run_index()
        self.assertEqual(
            os.stat(self.pm.PROGRESS_FILE).st_mode & 0o777, 0o600)

    def test_a_finished_scan_is_never_reported_as_running(self):
        """stage "done" means done, whatever the pid says."""
        self.pm.write_json(self.pm.PROGRESS_FILE,
                           {"stage": "done", "pid": self.live_indexer_pid(),
                            "startedAt": 1, "tracks": 9})
        out = io.StringIO()
        with redirect_stdout(out):
            self.pm.cmd_progress(None)
        self.assertFalse(json.loads(out.getvalue())["running"])

    def test_a_dead_indexer_is_not_reported_as_running(self):
        """A progress file outlives the process that wrote it."""
        self.pm.write_json(self.pm.PROGRESS_FILE,
                           {"stage": "tracks", "pid": 999999,
                            "startedAt": 1, "tracks": 5})
        out = io.StringIO()
        with redirect_stdout(out):
            self.pm.cmd_progress(None)
        self.assertFalse(json.loads(out.getvalue())["running"])

    def live_indexer_pid(self):
        """A real live process whose command line looks like ours.

        index_running() checks /proc/<pid>/cmdline rather than trusting the
        number, because a progress file outlives its writer — so the test needs
        a process that is genuinely alive and genuinely named.
        """
        import subprocess
        child = subprocess.Popen(
            ["python3", "-c", "import time; time.sleep(30)", "bin/plexmusic"])
        self.addCleanup(child.wait)
        self.addCleanup(child.kill)
        return child.pid

    def test_our_own_live_pid_counts_as_running(self):
        self.pm.write_json(self.pm.PROGRESS_FILE,
                           {"stage": "tracks", "pid": self.live_indexer_pid(),
                            "startedAt": 1, "tracks": 5})
        out = io.StringIO()
        with redirect_stdout(out):
            self.pm.cmd_progress(None)
        d = json.loads(out.getvalue())
        self.assertTrue(d["running"])
        self.assertEqual(d["tracks"], 5)

    def test_a_second_indexer_is_refused(self):
        """Two scans would fight over the same files for no benefit."""
        self.pm.write_json(self.pm.PROGRESS_FILE,
                           {"stage": "tracks", "pid": self.live_indexer_pid(),
                            "startedAt": 1})
        out = io.StringIO()
        with redirect_stdout(out):
            with self.assertRaises(SystemExit) as caught:
                self.pm.cmd_index(None)
        self.assertEqual(caught.exception.code, 5)
        self.assertIn("already running", json.loads(out.getvalue())["error"])

    def test_a_failed_progress_write_never_fails_the_scan(self):
        """Progress is a nicety. Losing it must not lose the index."""
        real_write = self.pm.write_json

        def refuse(path, data, mode=0o600):
            if path == self.pm.PROGRESS_FILE:
                raise OSError("no room")
            real_write(path, data, mode)

        with mock.patch.object(self.pm, "write_json", refuse):
            d = self.run_index()
        self.assertTrue(d["ok"])
        self.assertGreater(d["artistCount"], 0)


class ShellReloadTests(unittest.TestCase):
    """Service.qml cannot be instantiated here (it imports Quickshell), so the
    wiring is pinned by reading the source."""

    def setUp(self):
        with open(os.path.join(REPO, "Service.qml"), encoding="utf-8") as fh:
            self.service = fh.read()
        with open(os.path.join(REPO, "Panel.qml"), encoding="utf-8") as fh:
            self.panel = fh.read()

    def test_a_finished_scan_reloads_the_index_itself(self):
        """The ship-blocker: a FileView built before the file existed has no
        watch, so nothing ever told the panel the scan had finished."""
        self.assertIn("function reloadIndexFiles()", self.service)
        chunk = self.service[self.service.index("id: indexProc"):]
        chunk = chunk[:chunk.index("id: progressProc")]
        self.assertEqual(chunk.count("root.reloadIndexFiles()"), 2,
                         "both the normal end and the crash path must reload")

    def test_reloading_re_runs_the_load_rather_than_trusting_the_watcher(self):
        body = self.service[self.service.index("function reloadIndexFiles()"):]
        body = body[:body.index("\n  }")]
        for view in ("indexFile", "trackIndexFile"):
            self.assertIn('%s.path = ""' % view, body)
            self.assertIn("%s.path = root." % view, body)

    def test_the_stale_comment_is_gone(self):
        self.assertNotIn("The FileView watches the index file and reloads it",
                         self.service)

    def test_progress_is_polled_only_while_a_scan_runs(self):
        self.assertIn('command: [root.helper, "progress"]', self.service)
        chunk = self.service[self.service.index("id: progressTimer"):]
        chunk = chunk[:chunk.index("\n  }")]
        self.assertIn("running: root.indexing", chunk)

    def test_a_scan_that_outlived_the_shell_is_adopted(self):
        self.assertIn("d.running && !root.indexing", self.service)

    def test_every_view_shows_the_live_counts(self):
        self.assertIn("root.service.indexProgress", self.panel)
        # indexState is what all four empty states call.
        self.assertEqual(self.panel.count("root.indexState("), 4)

    def test_the_progress_line_names_artists_songs_and_elapsed(self):
        body = self.service[self.service.index("readonly property string indexProgress"):]
        body = body[:body.index("\n  }")]
        for bit in ("artists", "songs", "Scanning your library", "indexElapsed"):
            self.assertIn(bit, body)


if __name__ == "__main__":
    unittest.main()
