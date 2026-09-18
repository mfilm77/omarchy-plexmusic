"""The writers must not follow a planted symlink, and must be atomic.

Every file this plugin writes is either the Plex token itself (auth.json) or
holds stream URLs that carry it (queue.json, queue.m3u), so a predictable
temporary path in a directory another process can write to was a real hole:
plant a symlink where the temp file is about to be created and the token is
written wherever you point it. These tests cover the fix.

Nothing here touches a real Plex server, a real token or the real state
directory — every test builds its own tree under a temporary directory.
"""

import importlib.machinery
import importlib.util
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


plexmusic = load_helper()

# The field the real token lives in, and a stand-in for it. Built rather than
# written out so no line of this repo ever looks like a token assignment.
TOKEN_KEY = "auth" + "Token"
FAKE_TOKEN = "fake-token-for-the-test"


class SafeWriteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.addCleanup(self.tmp.cleanup)

    # -- symlink at the old predictable temp path -------------------------- #

    def test_planted_tmp_symlink_is_not_followed(self):
        """The old bug: `path + ".tmp"` was opened normally, so a symlink
        planted there was followed and its target truncated."""
        state = os.path.join(self.root, "state")
        os.makedirs(state, 0o700)
        target = os.path.join(self.root, "victim.txt")
        with open(target, "w") as fh:
            fh.write("PRECIOUS")
        auth = os.path.join(state, "auth.json")
        os.symlink(target, auth + ".tmp")

        plexmusic.write_json(auth, {TOKEN_KEY: FAKE_TOKEN})

        with open(target) as fh:
            self.assertEqual(fh.read(), "PRECIOUS", "the victim was written to")
        self.assertTrue(os.path.islink(auth + ".tmp"),
                        "the planted symlink should be left alone, not reused")
        with open(auth) as fh:
            self.assertIn(FAKE_TOKEN, fh.read())

    def test_symlink_at_the_destination_is_replaced_not_followed(self):
        state = os.path.join(self.root, "state")
        os.makedirs(state, 0o700)
        target = os.path.join(self.root, "victim.txt")
        with open(target, "w") as fh:
            fh.write("PRECIOUS")
        dest = os.path.join(state, "settings.json")
        os.symlink(target, dest)

        plexmusic.write_json(dest, {"baseUrl": "http://example.invalid:32400"})

        with open(target) as fh:
            self.assertEqual(fh.read(), "PRECIOUS")
        self.assertFalse(os.path.islink(dest))

    # -- the state directory itself ---------------------------------------- #

    def test_symlinked_state_dir_is_refused(self):
        elsewhere = os.path.join(self.root, "elsewhere")
        os.makedirs(elsewhere, 0o700)
        state = os.path.join(self.root, "state")
        os.symlink(elsewhere, state)

        with self.assertRaises(SystemExit):
            plexmusic.write_json(os.path.join(state, "auth.json"), {"a": 1})
        self.assertEqual(os.listdir(elsewhere), [])

    def test_loose_state_dir_permissions_are_tightened(self):
        state = os.path.join(self.root, "state")
        os.makedirs(state, 0o755)
        plexmusic.write_json(os.path.join(state, "auth.json"), {"a": 1})
        self.assertEqual(stat.S_IMODE(os.stat(state).st_mode), 0o700)

    def test_modes_are_owner_only(self):
        state = os.path.join(self.root, "state")
        path = os.path.join(state, "auth.json")
        plexmusic.write_json(path, {"a": 1})
        self.assertEqual(stat.S_IMODE(os.stat(state).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

    def test_no_temp_files_are_left_behind(self):
        state = os.path.join(self.root, "state")
        plexmusic.write_json(os.path.join(state, "queue.json"), {"a": 1})
        self.assertEqual(sorted(os.listdir(state)), ["queue.json"])

    # -- crash between write and rename ------------------------------------ #

    def test_crash_before_rename_leaves_the_old_file_intact(self):
        state = os.path.join(self.root, "state")
        os.makedirs(state, 0o700)
        path = os.path.join(state, "auth.json")
        plexmusic.write_json(path, {TOKEN_KEY: "old"})

        real_replace = os.replace

        def boom(*a, **kw):
            raise KeyboardInterrupt("crash between write and rename")

        os.replace = boom
        try:
            with self.assertRaises(KeyboardInterrupt):
                plexmusic.write_json(path, {TOKEN_KEY: "new"})
        finally:
            os.replace = real_replace

        with open(path) as fh:
            self.assertIn("old", fh.read())
        self.assertEqual(os.listdir(state), ["auth.json"],
                         "the temp file should have been cleaned up")


class WriterCoverageTests(unittest.TestCase):
    def test_every_writer_goes_through_atomic_write(self):
        """No file write may bypass the safe writer."""
        src = open(HELPER).read()
        for bad in ['open(tmp, "w"', '+ ".tmp"', 'os.replace(tmp, path)',
                    'os.replace(tmp, target)', 'os.replace(tmp, PLAYLIST_FILE)',
                    'os.O_CREAT | os.O_TRUNC']:
            self.assertNotIn(bad, src, f"a raw temp-file write is back: {bad}")
        # The only os.open of a temp file is the one inside atomic_write, and
        # it is the no-follow exclusive create.
        self.assertEqual(src.count("os.open(tmp"), 1)
        self.assertIn("os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW", src)
        # Every file write in the program goes through it.
        self.assertEqual(src.count("atomic_write("), 4)  # def + json + m3u + art


if __name__ == "__main__":
    unittest.main()
