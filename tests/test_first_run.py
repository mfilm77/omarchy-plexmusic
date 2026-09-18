"""A first run must end with an indexed library, or say why it did not.

The trap this covers: the settings page invites you to link the Plex account
and then add the server. The index attempt that fires after linking had no
address yet, so it died in `resolve_base()`; adding an address afterwards never
chose a music library and never tried again. The result was a linked,
reachable, correctly configured plugin with a permanently empty library and
nothing on screen to explain it.

Run from the repo root:  python3 -m unittest discover -s tests
No Plex server and no token: the network is a fake and the state is a temp dir.
"""

import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
HELPER = os.path.join(REPO, "bin", "plexmusic")

SECTIONS = {"MediaContainer": {"Directory": [
    {"key": "9", "type": "movie", "title": "Films"},
    {"key": "31", "type": "artist", "title": "Music"},
]}}


def load_helper():
    loader = importlib.machinery.SourceFileLoader("plexmusic_helper", HELPER)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class Args:
    def __init__(self, **kw):
        self.add = self.use = self.remove = None
        for k, v in kw.items():
            setattr(self, k, v)


class PinningAServerTests(unittest.TestCase):
    """`server --use` must leave the plugin ready to index."""

    def setUp(self):
        self.pm = load_helper()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        state = os.path.join(self.tmp.name, "config")
        self.pm.CONFIG_DIR = state
        self.pm.AUTH_FILE = os.path.join(state, "auth.json")
        self.pm.SETTINGS_FILE = os.path.join(state, "settings.json")
        self.pm.CACHE_DIR = os.path.join(self.tmp.name, "cache")
        self.pm.LOG_FILE = os.path.join(self.pm.CACHE_DIR, "plexmusic.log")
        # A linked account, as it is straight after the link poll succeeds.
        self.pm.write_json(self.pm.AUTH_FILE,
                           {"auth" + "Token": "fake", "clientIdentifier": "cid"})

    def run_server(self, uri, reachable=True, sections=SECTIONS):
        """`plexmusic server --use <uri>` with the network faked out."""
        with mock.patch.object(self.pm.Plex, "reachable",
                               lambda self, base, timeout=2.5:
                               0.01 if reachable else None), \
             mock.patch.object(self.pm.Plex, "get",
                               lambda self, path, *a, **kw: sections):
            out = io.StringIO()
            with redirect_stdout(out):
                self.pm.cmd_server(Args(use=uri))
        return json.loads(out.getvalue())

    def test_pinning_a_reachable_server_chooses_the_music_library(self):
        d = self.run_server("http://plex.example:32400")
        self.assertTrue(d["ok"])
        self.assertTrue(d["reachable"])
        self.assertEqual(d["active"], "http://plex.example:32400")
        # The bug: this used to be unset, so nothing could index.
        self.assertEqual(d["section"], "31")
        saved = self.pm.read_json(self.pm.SETTINGS_FILE, {})
        self.assertEqual(saved["musicSection"], "31")

    def test_an_existing_choice_is_not_overwritten(self):
        self.pm.write_json(self.pm.SETTINGS_FILE, {"musicSection": "44"})
        d = self.run_server("http://plex.example:32400")
        self.assertEqual(d["section"], "44")

    def test_an_unreachable_server_is_kept_but_not_pinned(self):
        d = self.run_server("http://nowhere.example:32400", reachable=False)
        self.assertFalse(d["reachable"])
        self.assertIsNone(d["active"])
        self.assertIn("http://nowhere.example:32400", d["servers"])

    def test_a_server_with_no_music_library_is_still_usable(self):
        """No music section is a reason to ask the user, not to fail."""
        d = self.run_server("http://plex.example:32400",
                            sections={"MediaContainer": {"Directory": [
                                {"key": "9", "type": "movie", "title": "Films"}]}})
        self.assertTrue(d["ok"])
        self.assertTrue(d["reachable"])
        self.assertEqual(d["section"], "")


class FailureLogTests(unittest.TestCase):
    def setUp(self):
        self.pm = load_helper()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.pm.CACHE_DIR = os.path.join(self.tmp.name, "cache")
        self.pm.LOG_FILE = os.path.join(self.pm.CACHE_DIR, "plexmusic.log")

    def read_log(self):
        with open(self.pm.LOG_FILE) as fh:
            return fh.read()

    def test_a_failure_is_recorded(self):
        self.pm.log_failure("no Plex server reachable")
        self.assertIn("no Plex server reachable", self.read_log())

    def test_die_writes_the_log_and_still_prints_its_json(self):
        out = io.StringIO()
        with redirect_stdout(out):
            with self.assertRaises(SystemExit):
                self.pm.die("not linked to Plex", code=2)
        self.assertEqual(json.loads(out.getvalue())["error"], "not linked to Plex")
        self.assertIn("not linked to Plex", self.read_log())

    def test_a_token_is_never_written_to_the_log(self):
        # Built from parts so no line of this repo looks like a real token.
        secret = "SECRET" + "VALUE123"
        self.pm.log_failure("HTTP 500 for http://plex.example/x?"
                            + "X-Plex-" + "Token=" + secret + "&y=1")
        log = self.read_log()
        self.assertNotIn(secret, log)
        self.assertIn("<redacted>", log)
        self.assertIn("&y=1", log, "only the token should be removed")

    def test_the_log_is_owner_only_and_bounded(self):
        for i in range(self.pm.LOG_LINES + 40):
            self.pm.log_failure("failure %d" % i)
        lines = self.read_log().splitlines()
        self.assertEqual(len(lines), self.pm.LOG_LINES)
        self.assertIn("failure %d" % (self.pm.LOG_LINES + 39), lines[-1])
        self.assertNotIn("failure 0", self.read_log())
        self.assertEqual(os.stat(self.pm.LOG_FILE).st_mode & 0o777, 0o600)

    def test_an_unwritable_log_never_masks_the_real_error(self):
        """The log lives under the same safe writer, which refuses a symlinked
        directory by calling die() — that must not become the error the user
        sees, and must not recurse."""
        os.makedirs(os.path.join(self.tmp.name, "elsewhere"))
        os.symlink(os.path.join(self.tmp.name, "elsewhere"), self.pm.CACHE_DIR)
        out = io.StringIO()
        with redirect_stdout(out):
            with self.assertRaises(SystemExit):
                self.pm.die("the real error")
        self.assertEqual(json.loads(out.getvalue())["error"], "the real error")


class IndexReportTests(unittest.TestCase):
    def test_skipped_tracks_are_counted(self):
        pm = load_helper()
        plex = pm.Plex.__new__(pm.Plex)
        plex.section = "31"
        page = {"MediaContainer": {"totalSize": 3, "Metadata": [
            {"ratingKey": 1, "title": "A"},
            {"ratingKey": 2, "title": ""},          # no title: dropped
            {"ratingKey": 3, "title": "C"},
        ]}}
        with mock.patch.object(pm.Plex, "get", lambda self, p, *a, **kw: page):
            tracks = plex.all_tracks(page=3)
        self.assertEqual(len(tracks), 2)
        self.assertEqual(plex.track_total, 3)
        self.assertEqual(plex.track_skipped, 1)


class ServiceWiringTests(unittest.TestCase):
    """Service.qml cannot be instantiated here (it imports Quickshell), so the
    wiring is pinned by reading the source — the same approach the A1 and B1
    tests use for panel wiring."""

    def setUp(self):
        with open(os.path.join(REPO, "Service.qml"), encoding="utf-8") as fh:
            self.service = fh.read()
        with open(os.path.join(REPO, "Panel.qml"), encoding="utf-8") as fh:
            self.panel = fh.read()

    def test_a_pinned_server_triggers_an_index(self):
        self.assertIn("d.reachable && root.linked && root.artistCount === 0",
                      self.service)

    def test_an_install_already_stuck_heals_itself_once(self):
        self.assertIn("firstIndexTried", self.service)
        self.assertIn("!d.indexedAt && root.artistCount === 0", self.service)

    def test_reindex_says_why_it_cannot_start(self):
        chunk = self.service[self.service.index("function reindex()"):]
        chunk = chunk[:chunk.index("indexProc.running = true")]
        self.assertIn("not linked to Plex yet", chunk)
        self.assertIn("no Plex server yet", chunk)
        self.assertIn("showToast", chunk)

    def test_a_silent_helper_clears_the_indexing_flag(self):
        """D3: `indexing` stuck true disabled Rescan until a shell restart."""
        chunk = self.service[self.service.index("target: indexProc"):]
        chunk = chunk[:chunk.index("\n  }")]
        self.assertIn("root.indexing = false", chunk)
        self.assertIn("exit ", chunk)

    def test_every_empty_state_reports_an_index_in_progress(self):
        """D1: the default (favourites) view gave no sign an index was running."""
        self.assertIn("function indexState(idle)", self.panel)
        self.assertEqual(self.panel.count("root.indexState("), 4)
        self.assertIn(
            'root.indexState("Tap the star on any artist to keep them here.")',
            self.panel)

    def test_a_refused_index_keeps_its_reason(self):
        """N1 from the security review: the error was cleared on the way out."""
        chunk = self.service[self.service.index("function boundedIndexList"):]
        self.assertIn("if (list === null) return null", chunk[:400])
        for fn in ("function applyIndex()", "function applyTrackIndex()"):
            body = self.service[self.service.index(fn):]
            body = body[:body.index("var idx = {}")]
            self.assertIn("if (d === null) return", body)


class VersionTests(unittest.TestCase):
    def test_the_version_is_the_same_everywhere(self):
        with open(os.path.join(REPO, "manifest.json")) as fh:
            manifest = json.load(fh)
        with open(HELPER) as fh:
            helper = fh.read()
        self.assertIn('PLEX_VERSION = "%s"' % manifest["version"], helper)

    def test_the_changelog_covers_this_version(self):
        with open(os.path.join(REPO, "manifest.json")) as fh:
            version = json.load(fh)["version"]
        with open(os.path.join(REPO, "CHANGELOG.md")) as fh:
            self.assertIn("## %s" % version, fh.read())


class HelperEndToEndTests(unittest.TestCase):
    """The real binary, in a scratch HOME, with no server to talk to."""

    def test_index_without_a_server_fails_loudly_and_is_logged(self):
        with tempfile.TemporaryDirectory() as home:
            cfg = os.path.join(home, ".config", "omarchy-plex-music")
            os.makedirs(cfg, 0o700)
            with open(os.path.join(cfg, "auth.json"), "w") as fh:
                json.dump({"auth" + "Token": "fake-not-a-real-token"}, fh)
            os.chmod(os.path.join(cfg, "auth.json"), 0o600)
            env = dict(os.environ, HOME=home)
            out = subprocess.run([HELPER, "index"], capture_output=True,
                                 text=True, env=env, timeout=120)
            d = json.loads(out.stdout)
            self.assertFalse(d["ok"])
            self.assertIn("no Plex server reachable", d["error"])
            log = os.path.join(home, ".cache", "omarchy-plex-music",
                               "plexmusic.log")
            self.assertTrue(os.path.exists(log), "the failure was not logged")
            with open(log) as fh:
                self.assertIn("no Plex server reachable", fh.read())
            self.assertNotIn("fake-not-a-real-token", open(log).read())


if __name__ == "__main__":
    unittest.main()
