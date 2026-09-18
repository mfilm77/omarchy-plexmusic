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
import time
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
        # The index lock is a real flock held for the life of the process, so
        # every test needs its own or they lock each other out.
        self.pm.LOCK_FILE = os.path.join(data, "index.lock")
        self.addCleanup(self.release_lock)
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

    def release_lock(self):
        """Drop the flock this test's cmd_index took; a real run drops it by
        exiting."""
        fd = getattr(self.pm, "_index_lock_fd", None)
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
            self.pm._index_lock_fd = None

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

    def hold_the_lock(self):
        """Take the index lock the way a running indexer holds it."""
        import fcntl
        os.makedirs(os.path.dirname(self.pm.LOCK_FILE), 0o700, exist_ok=True)
        fd = os.open(self.pm.LOCK_FILE, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.addCleanup(os.close, fd)
        return fd

    def test_a_held_lock_reads_as_a_running_scan(self):
        self.hold_the_lock()
        self.pm.write_json(self.pm.PROGRESS_FILE,
                           {"stage": "tracks", "startedAt": 1, "tracks": 5})
        out = io.StringIO()
        with redirect_stdout(out):
            self.pm.cmd_progress(None)
        d = json.loads(out.getvalue())
        self.assertTrue(d["running"])
        self.assertEqual(d["tracks"], 5)

    def test_a_second_indexer_is_refused(self):
        """Two scans would fight over the same files for no benefit."""
        self.hold_the_lock()
        out = io.StringIO()
        with redirect_stdout(out):
            with self.assertRaises(SystemExit) as caught:
                self.pm.cmd_index(None)
        self.assertEqual(caught.exception.code, 5)
        self.assertIn("already running", json.loads(out.getvalue())["error"])

    def test_two_starters_racing_cannot_both_index(self):
        """The case the old check-then-act guard let through: both read the
        progress file before either had written one, so both proceeded."""
        self.assertFalse(os.path.exists(self.pm.PROGRESS_FILE))
        other = load_helper()
        other.DATA_DIR = self.pm.DATA_DIR
        other.LOCK_FILE = self.pm.LOCK_FILE
        other.PROGRESS_FILE = self.pm.PROGRESS_FILE
        self.assertTrue(other.take_index_lock(), "the first starter must win")
        self.addCleanup(self.release_other, other)
        # Nothing has been published yet — the old guard had nothing to see.
        self.assertFalse(os.path.exists(self.pm.PROGRESS_FILE))
        self.assertFalse(self.pm.take_index_lock(), "the second one got in too")

    def release_other(self, other):
        fd = getattr(other, "_index_lock_fd", None)
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass

    def test_a_killed_indexer_leaves_no_stale_lock(self):
        """The kernel drops an flock when its holder dies, so there is no
        stale-lock heuristic that could take one from a live indexer."""
        import subprocess
        os.makedirs(os.path.dirname(self.pm.LOCK_FILE), 0o700, exist_ok=True)
        holder = subprocess.Popen(
            ["python3", "-c",
             "import fcntl,os,sys,time;"
             "fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT, 0o600);"
             "fcntl.flock(fd, fcntl.LOCK_EX);"
             "print('held', flush=True); time.sleep(60)",
             self.pm.LOCK_FILE],
            stdout=subprocess.PIPE, text=True)
        self.addCleanup(holder.wait)
        self.addCleanup(holder.kill)
        self.assertEqual(holder.stdout.readline().strip(), "held")
        self.assertFalse(self.pm.take_index_lock(), "a live holder was ignored")
        holder.kill()
        holder.wait()
        self.assertTrue(self.pm.take_index_lock(),
                        "the dead holder's lock was never released")

    def test_the_pid_fallback_still_works_without_locking(self):
        """On a filesystem that cannot lock, the recorded pid is the fallback."""
        self.pm.write_json(self.pm.PROGRESS_FILE,
                           {"stage": "tracks", "pid": self.live_indexer_pid(),
                            "startedAt": 1, "tracks": 5})
        out = io.StringIO()
        with mock.patch.object(self.pm, "lock_is_held", lambda: None):
            with redirect_stdout(out):
                self.pm.cmd_progress(None)
        self.assertTrue(json.loads(out.getvalue())["running"])

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


class BoundedProgressTests(unittest.TestCase):
    """SEC-4: cap what is published. The progress record is the one thing a
    running scan tells the shell, and it goes straight into shell properties."""

    def setUp(self):
        self.pm = load_helper()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        data = os.path.join(self.tmp.name, "data")
        self.pm.DATA_DIR = data
        self.pm.PROGRESS_FILE = os.path.join(data, "index-progress.json")
        self.pm.LOCK_FILE = os.path.join(data, "index.lock")
        self.pm.CACHE_DIR = os.path.join(self.tmp.name, "cache")
        self.pm.LOG_FILE = os.path.join(self.pm.CACHE_DIR, "plexmusic.log")

    def test_the_stage_is_clamped_on_the_way_in(self):
        """The hole William proved: 200,000 characters reached the shell."""
        self.pm.write_json(self.pm.PROGRESS_FILE,
                           {"stage": "x" * 200000, "pid": 1, "startedAt": 1})
        out = io.StringIO()
        with redirect_stdout(out):
            self.pm.cmd_progress(None)
        stage = json.loads(out.getvalue())["stage"]
        self.assertEqual(len(stage), self.pm.MAX_STAGE_CHARS)

    def test_every_published_field_is_a_bounded_number_or_a_short_word(self):
        out = self.pm.bounded_progress(
            {"stage": "t" * 500, "artists": "12", "tracks": None,
             "trackTotal": "junk", "startedAt": 5, "pid": 7,
             "somethingElse": "x" * 1000})
        self.assertEqual(len(out["stage"]), self.pm.MAX_STAGE_CHARS)
        self.assertEqual(out["artists"], 12)
        self.assertEqual(out["tracks"], 0)
        self.assertEqual(out["trackTotal"], 0)
        self.assertNotIn("somethingElse", out,
                         "only known fields may be published")

    def test_the_file_a_scan_writes_is_bounded_too(self):
        """Bounded on the way out as well as on the way back in."""
        src = open(HELPER).read()
        self.assertIn("write_json(PROGRESS_FILE, bounded_progress(state)", src)

    def test_the_shell_refuses_an_oversized_progress_record(self):
        with open(os.path.join(REPO, "Service.qml"), encoding="utf-8") as fh:
            qml = fh.read()
        self.assertIn("maxProgressBytes", qml)
        chunk = qml[qml.index("id: progressProc"):]
        chunk = chunk[:chunk.index("id: progressTimer")]
        self.assertIn("> root.maxProgressBytes", chunk)
        self.assertIn("root.maxStageChars", chunk)


class QuietFailureTests(unittest.TestCase):
    """`now` is polled twice a second while music plays. One call, one object."""

    def setUp(self):
        self.pm = load_helper()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.pm.CACHE_DIR = os.path.join(self.tmp.name, "cache")
        self.pm.LOG_FILE = os.path.join(self.pm.CACHE_DIR, "plexmusic.log")

    def test_a_handled_failure_prints_nothing(self):
        out = io.StringIO()
        with redirect_stdout(out):
            with self.pm.quiet():
                with self.assertRaises(self.pm.PlexUnavailable):
                    self.pm.die("no Plex server reachable", code=3)
        self.assertEqual(out.getvalue(), "",
                         "a caught die() still answered on stdout")

    def test_an_unhandled_failure_still_answers_normally(self):
        out = io.StringIO()
        with redirect_stdout(out):
            with self.assertRaises(SystemExit):
                self.pm.die("no Plex server reachable", code=3)
        self.assertEqual(json.loads(out.getvalue())["error"],
                         "no Plex server reachable")

    def test_quiet_nests_and_restores(self):
        with self.pm.quiet():
            with self.pm.quiet():
                pass
            with self.assertRaises(self.pm.PlexUnavailable):
                self.pm.die("inner")
        with self.assertRaises(SystemExit):
            with redirect_stdout(io.StringIO()):
                self.pm.die("outer")

    def test_the_artwork_call_chain_stays_silent_when_plex_is_gone(self):
        """The real shape of the bug, exercised rather than asserted: the exact
        sequence `now` runs for an uncached cover, with nothing reachable."""
        self.pm.CONFIG_DIR = os.path.join(self.tmp.name, "config")
        self.pm.AUTH_FILE = os.path.join(self.pm.CONFIG_DIR, "auth.json")
        self.pm.SETTINGS_FILE = os.path.join(self.pm.CONFIG_DIR, "settings.json")
        self.pm.write_json(self.pm.AUTH_FILE, {"auth" + "Token": "fake"})
        self.pm.write_json(self.pm.SETTINGS_FILE,
                           {"baseUrl": "http://127.0.0.1:1",
                            "servers": ["http://127.0.0.1:1"]})
        out = io.StringIO()
        with redirect_stdout(out):
            try:
                with self.pm.quiet():
                    plex = self.pm.Plex()
                    plex.resolve_base()
                    plex.art_path("/library/metadata/1/thumb/1")
                art_failed = False
            except self.pm.PlexUnavailable:
                art_failed = True
        self.assertTrue(art_failed, "an unreachable server should be reported")
        self.assertEqual(out.getvalue(), "",
                         "the failure printed a second JSON object")

    def test_the_old_swallowed_systemexit_is_gone(self):
        src = open(HELPER).read()
        self.assertIn("with quiet():", src)
        self.assertNotIn("except SystemExit:", src)


class LogDiscipline(unittest.TestCase):
    """FA-3: the reason is in the log, once, in plain words."""

    def setUp(self):
        self.pm = load_helper()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.pm.CACHE_DIR = os.path.join(self.tmp.name, "cache")
        self.pm.LOG_FILE = os.path.join(self.pm.CACHE_DIR, "plexmusic.log")

    def lines(self):
        with open(self.pm.LOG_FILE) as fh:
            return [l for l in fh.read().splitlines() if l]

    def test_a_repeating_failure_stays_one_line(self):
        """A poll every 500 ms would otherwise write 200 identical lines and
        evict the history the log exists to keep."""
        self.pm.log_failure("a real earlier problem")
        for _ in range(300):
            self.pm.log_failure("now: no artwork (cannot reach Plex)")
        lines = self.lines()
        self.assertEqual(len(lines), 2, lines)
        self.assertIn("a real earlier problem", lines[0])
        self.assertIn("no artwork", lines[1])

    def test_a_repeat_is_rewritten_at_most_once_per_window(self):
        self.pm.log_failure("same thing")
        first = self.lines()[-1]
        self.pm.log_failure("same thing")
        self.assertEqual(self.lines()[-1], first, "it wrote again immediately")
        # Age the stored line past the window and it may say so, once.
        aged = time.strftime("%Y-%m-%d %H:%M:%S",
                             time.localtime(time.time() - 600))
        self.pm.atomic_write(self.pm.LOG_FILE,
                             ("%s same thing\n" % aged).encode(), 0o600)
        self.pm.log_failure("same thing")
        self.assertEqual(len(self.lines()), 1)
        self.assertIn(self.pm.REPEAT_SUFFIX.strip(), self.lines()[-1])

    def test_a_different_failure_is_always_recorded(self):
        self.pm.log_failure("problem one")
        self.pm.log_failure("problem two")
        self.assertEqual(len(self.lines()), 2)

    def test_the_log_reader_does_not_follow_a_symlink(self):
        os.makedirs(self.pm.CACHE_DIR, 0o700)
        secret = os.path.join(self.tmp.name, "elsewhere.txt")
        with open(secret, "w") as fh:
            fh.write("PRIVATE CONTENT\n")
        os.symlink(secret, self.pm.LOG_FILE)
        self.pm.log_failure("a failure")
        # The symlink is replaced by a real file; the target is untouched and
        # none of it was copied into the log.
        self.assertFalse(os.path.islink(self.pm.LOG_FILE))
        with open(secret) as fh:
            self.assertEqual(fh.read(), "PRIVATE CONTENT\n")
        with open(self.pm.LOG_FILE) as fh:
            body = fh.read()
        self.assertNotIn("PRIVATE CONTENT", body)
        self.assertIn("a failure", body)

    def test_the_reader_takes_the_tail_not_the_whole_file(self):
        os.makedirs(self.pm.CACHE_DIR, 0o700)
        with open(self.pm.LOG_FILE, "w") as fh:
            fh.write("x" * (self.pm.LOG_MAX_BYTES * 2))
        os.chmod(self.pm.LOG_FILE, 0o600)
        got = self.pm.read_tail_nofollow(self.pm.LOG_FILE,
                                         self.pm.LOG_MAX_BYTES)
        self.assertEqual(len(got), self.pm.LOG_MAX_BYTES)

    def test_a_huge_log_is_trimmed_back_to_its_cap(self):
        os.makedirs(self.pm.CACHE_DIR, 0o700)
        with open(self.pm.LOG_FILE, "w") as fh:
            for i in range(5000):
                fh.write("2026-01-01 00:00:00 old line %d\n" % i)
        os.chmod(self.pm.LOG_FILE, 0o600)
        self.pm.log_failure("something new")
        self.assertLessEqual(len(self.lines()), self.pm.LOG_LINES)
        self.assertIn("something new", self.lines()[-1])


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
