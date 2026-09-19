"""The readers must be as careful as the writers.

The writers were hardened first (test_safe_write.py), and then the log reader.
What was left was `read_json()` — a plain `open()` behind fifteen call sites,
including `auth.json` (the Plex token) and `queue.json` (URLs that carry it).
A symlink planted in place of one of those files was read through, and the
parse had no byte ceiling. These tests cover that fix, the owner-only mode on
the two index files, the notice a user gets when their symlinked config file
is replaced, and the ceiling on an mpv IPC reply.

Nothing here touches a real Plex server, a real token, a real mpv or the real
state directory: every test builds its own tree under a temporary directory,
and the mpv socket is a fake object, not a socket.
"""

import importlib.machinery
import importlib.util
import json
import os
import stat
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
HELPER = os.path.join(REPO, "bin", "plexmusic")


def load_helper():
    loader = importlib.machinery.SourceFileLoader("plexmusic_helper", HELPER)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


SECRET = "TOPSECRET-not-a-real-token"


class ReadJsonGuardTests(unittest.TestCase):
    def setUp(self):
        self.pm = load_helper()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name
        self.state = os.path.join(self.root, "state")
        os.makedirs(self.state, 0o700)

    def path(self, name):
        return os.path.join(self.state, name)

    # -- the ordinary behaviour, unchanged --------------------------------- #

    def test_a_normal_file_still_reads(self):
        p = self.path("settings.json")
        self.pm.write_json(p, {"baseUrl": "http://plex.example:32400"})
        self.assertEqual(self.pm.read_json(p, {})["baseUrl"],
                         "http://plex.example:32400")

    def test_a_missing_file_returns_the_default(self):
        self.assertEqual(self.pm.read_json(self.path("nope.json"), {"d": 1}),
                         {"d": 1})
        self.assertIsNone(self.pm.read_json(self.path("nope.json"), None))

    def test_malformed_json_returns_the_default_not_a_traceback(self):
        p = self.path("settings.json")
        with open(p, "w") as fh:
            fh.write("{this is not json")
        self.assertEqual(self.pm.read_json(p, {"d": 1}), {"d": 1})

    def test_a_directory_is_not_read_as_json(self):
        self.assertEqual(self.pm.read_json(self.state, {"d": 1}), {"d": 1})

    # -- an index left 0644 by an older version ---------------------------- #

    def test_a_loose_mode_file_is_still_read(self):
        """0.1.0 and the 0.2.0 test builds wrote artists.json 0644. Those
        files must keep working — they are tightened on the next write, not
        refused on the next read."""
        p = self.path("artists.json")
        self.pm.write_json(p, {"artists": [{"title": "A"}]})
        os.chmod(p, 0o644)
        self.assertEqual(len(self.pm.read_json(p, {}).get("artists", [])), 1)

    def test_a_loose_mode_file_is_tightened_on_the_next_write(self):
        p = self.path("artists.json")
        with open(p, "w") as fh:
            json.dump({"artists": []}, fh)
        os.chmod(p, 0o644)
        self.pm.write_json(p, {"artists": [{"title": "A"}]})
        self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o600)

    # -- the fix ----------------------------------------------------------- #

    def test_a_symlinked_json_file_is_not_followed(self):
        """The whole point: a link planted where auth.json lives must not be
        read through, and nothing of its target may come back."""
        target = os.path.join(self.root, "victim.json")
        with open(target, "w") as fh:
            json.dump({"auth" + "Token": SECRET}, fh)
        link = self.path("auth.json")
        os.symlink(target, link)

        got = self.pm.read_json(link, {"default": True})

        self.assertEqual(got, {"default": True})
        self.assertNotIn(SECRET, json.dumps(got))
        self.assertTrue(os.path.islink(link), "the reader must not touch it")
        with open(target) as fh:
            self.assertIn(SECRET, fh.read(), "the target was modified")

    def test_a_file_over_the_ceiling_is_refused(self):
        p = self.path("tracks.json")
        with open(p, "w") as fh:
            fh.write(json.dumps({"pad": "x" * 5000}))
        self.assertEqual(self.pm.read_json(p, {"d": 1}, max_bytes=1024),
                         {"d": 1})

    def test_a_file_exactly_at_the_ceiling_still_reads(self):
        p = self.path("tracks.json")
        blob = json.dumps({"pad": "x" * 100})
        with open(p, "w") as fh:
            fh.write(blob)
        self.assertEqual(
            self.pm.read_json(p, None, max_bytes=len(blob))["pad"],
            "x" * 100)

    def test_the_default_ceiling_is_the_json_cap(self):
        self.assertEqual(self.pm.read_json.__defaults__[-1],
                         self.pm.MAX_JSON_BYTES)

    def test_a_multi_chunk_file_reads_whole(self):
        """The read loop must reassemble a file larger than one chunk."""
        p = self.path("tracks.json")
        rows = [{"title": "t%d" % i} for i in range(20000)]
        self.pm.write_json(p, {"tracks": rows})
        self.assertEqual(len(self.pm.read_json(p, {})["tracks"]), 20000)


class ReaderCoverageTests(unittest.TestCase):
    def test_no_plain_open_is_left_for_our_own_files(self):
        src = open(HELPER).read()
        # One parse, inside read_json.
        self.assertEqual(src.count("json.loads(bytes(raw)"), 1)
        self.assertNotIn('with open(path, "r", encoding="utf-8") as fh:', src)
        # The only remaining plain open() is /proc/<pid>/cmdline, which is
        # kernel-backed, bounded, and cannot be a symlink to a user file.
        self.assertEqual(src.count("open(f\"/proc/"), 1)
        # Both readers refuse to follow a link.
        self.assertEqual(src.count("os.O_RDONLY | os.O_NOFOLLOW"), 2)

    def test_no_unbounded_read_is_left(self):
        """The release standard's SEC-3 check is `grep "\\.read()" bin/*` →
        no hits at all. The one /proc read is taken with a length."""
        self.assertNotIn(".read()", open(HELPER).read())

    def test_the_index_is_not_written_world_readable(self):
        src = open(HELPER).read()
        self.assertNotIn("0o644", src)
        self.assertNotIn("0o755", src)

    def test_only_the_owner_ever_reads_the_index(self):
        """Why 0600 is safe for the shell: the FileViews read a path under the
        shell's own $HOME, in the same session and as the same user that wrote
        it, and nothing in the plugin runs anything as another user."""
        qml = open(os.path.join(REPO, "Service.qml")).read()
        self.assertIn('Quickshell.env("HOME")', qml)
        for path in ("Service.qml", "Panel.qml", "BarWidget.qml"):
            src = open(os.path.join(REPO, path)).read()
            for bad in ("sudo", "pkexec", "systemd-run", "su -"):
                self.assertNotIn(bad, src, f"{path} runs something as another user")
        # And the helper is the only other reader of the two index files.
        helper = open(HELPER).read()
        self.assertEqual(helper.count("read_json(ARTISTS_FILE"), 2)
        self.assertEqual(helper.count("read_json(TRACKS_FILE"), 0)


class SymlinkedFileNoticeTests(unittest.TestCase):
    """Case A: a symlinked individual file is replaced by a real file. That is
    deliberate, but the user must not lose their stow/chezmoi link in silence."""

    def setUp(self):
        self.pm = load_helper()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = os.path.join(self.tmp.name, "state")
        os.makedirs(self.state, 0o700)
        self.pm.CACHE_DIR = os.path.join(self.tmp.name, "cache")
        self.pm.LOG_FILE = os.path.join(self.pm.CACHE_DIR, "plexmusic.log")

    def log(self):
        if not os.path.exists(self.pm.LOG_FILE):
            return ""
        with open(self.pm.LOG_FILE) as fh:
            return fh.read()

    def test_replacing_a_symlinked_file_says_so_in_the_log(self):
        target = os.path.join(self.tmp.name, "dotfiles-settings.json")
        with open(target, "w") as fh:
            fh.write("{}")
        dest = os.path.join(self.state, "settings.json")
        os.symlink(target, dest)

        self.pm.write_json(dest, {"baseUrl": "http://plex.example:32400"})

        self.assertFalse(os.path.islink(dest))
        self.assertIn("was a symlink", self.log())
        self.assertIn("settings.json", self.log())
        with open(target) as fh:
            self.assertEqual(fh.read(), "{}", "the link target was written to")

    def test_an_ordinary_write_says_nothing(self):
        dest = os.path.join(self.state, "settings.json")
        self.pm.write_json(dest, {"a": 1})
        self.pm.write_json(dest, {"a": 2})
        self.assertEqual(self.log(), "")


class FakeSocket:
    """Stands in for the mpv IPC socket: serves `payload` in 64 KB pieces and
    counts what the caller actually took."""

    def __init__(self, payload):
        self.payload = payload
        self.served = 0
        self.sent = b""

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def settimeout(self, t):
        pass

    def connect(self, path):
        pass

    def sendall(self, data):
        self.sent += data

    def recv(self, size):
        chunk = self.payload[self.served:self.served + size]
        self.served += len(chunk)
        return chunk


class MpvReplyCapTests(unittest.TestCase):
    def setUp(self):
        self.pm = load_helper()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        # mpv_request only asks that the socket path exists.
        self.pm.IPC_SOCKET = os.path.join(self.tmp.name, "sock")
        open(self.pm.IPC_SOCKET, "w").close()

    def run_with(self, payload):
        fake = FakeSocket(payload)

        class FakeSocketModule:
            AF_UNIX = 1
            SOCK_STREAM = 1
            timeout = OSError

            @staticmethod
            def socket(family, kind):
                return fake

        real = self.pm.socket
        self.pm.socket = FakeSocketModule
        try:
            return self.pm.mpv_request(["get_property", "path"]), fake
        finally:
            self.pm.socket = real

    def test_a_normal_reply_still_comes_back(self):
        reply = json.dumps({"error": "success", "data": "/tmp/x.flac"})
        got, fake = self.run_with(reply.encode("utf-8") + b"\n")
        self.assertEqual(got["data"], "/tmp/x.flac")
        self.assertIn(b"get_property", fake.sent)

    def test_a_flood_is_cut_off_at_the_ceiling(self):
        """No newline ever arrives, so before the fix this accumulated for the
        whole 1.5 s timeout. Now it stops one byte over the cap."""
        got, fake = self.run_with(b"x" * (4 * 1024 * 1024))
        self.assertIsNone(got)
        self.assertLessEqual(fake.served, self.pm.MAX_IPC_BYTES + 1)

    def test_the_ceiling_is_far_above_a_real_reply(self):
        self.assertGreaterEqual(self.pm.MAX_IPC_BYTES, 1024 * 1024)


if __name__ == "__main__":
    unittest.main()
