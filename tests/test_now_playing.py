"""What is playing carries the keys that open its album (addition A1).

The panel's now-playing line jumps to the playing track's album. That must go
by the Plex keys the helper reports for the current track, never by searching
for a name, and it has to pick the right track when mpv shuffled the queue.

Run from the repo root:  python3 -m unittest discover -s tests
"""

import importlib.machinery
import importlib.util
import io
import json
import os
import re
import unittest
from contextlib import redirect_stdout
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))


def load_helper():
    loader = importlib.machinery.SourceFileLoader(
        "plexmusic_helper_now", os.path.join(REPO, "bin", "plexmusic"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def track(key, album, artist, part):
    return {"key": key, "title": f"t{key}", "album": f"album {album}", "artist": "Kate Bush",
            "albumKey": album, "artistKey": artist, "albumYear": 2005,
            "part": f"/library/parts/{part}/file.flac", "duration": 1000}


QUEUE = {"shuffle": False, "tracks": [
    track("11", "500", "90", "701"),
    track("12", "500", "90", "702"),
    track("21", "600", "91", "801"),
]}


class CurrentEntryTest(unittest.TestCase):
    def setUp(self):
        self.pm = load_helper()

    def test_matches_by_part_key_in_mpv_path(self):
        path = "http://plex.example:32400/library/parts/801/file.flac?X-Plex-Token=abc"
        self.assertEqual(self.pm.current_entry(QUEUE, path, 0)["albumKey"], "600")

    def test_part_match_wins_over_position(self):
        path = "http://h/library/parts/702/file.flac"
        self.assertEqual(self.pm.current_entry(QUEUE, path, 2)["key"], "12")

    def test_shuffled_queue_never_trusts_the_position(self):
        shuffled = dict(QUEUE, shuffle=True)
        self.assertEqual(self.pm.current_entry(shuffled, "", 2), {})
        self.assertEqual(self.pm.current_entry(shuffled, "http://h/other", 2), {})

    def test_unshuffled_queue_falls_back_to_position(self):
        self.assertEqual(self.pm.current_entry(QUEUE, "", 2)["artistKey"], "91")

    def test_bad_positions_and_empty_queue(self):
        for pos in (None, -1, 3, True, "1"):
            self.assertEqual(self.pm.current_entry(QUEUE, "", pos), {}, pos)
        self.assertEqual(self.pm.current_entry({}, "http://h/library/parts/701/x", 0), {})


class TracksCarryKeysTest(unittest.TestCase):
    def test_tracks_at_reports_album_and_artist_keys(self):
        pm = load_helper()
        plex = pm.Plex.__new__(pm.Plex)
        listing = {"MediaContainer": {"Metadata": [{
            "type": "track", "ratingKey": 11, "title": "King of the Mountain", "index": 1,
            "parentTitle": "Aerial", "grandparentTitle": "Kate Bush",
            "parentRatingKey": 500, "grandparentRatingKey": 90, "parentYear": 2005,
            "duration": 293000, "parentThumb": "/library/metadata/500/thumb/1",
            "Media": [{"Part": [{"key": "/library/parts/701/file.flac"}]}],
        }]}}
        with mock.patch.object(pm.Plex, "get", return_value=listing):
            (t,) = plex.tracks_at("/library/metadata/500/children")
        self.assertEqual((t["albumKey"], t["artistKey"], t["albumYear"]), ("500", "90", 2005))


class NowEmitsKeysTest(unittest.TestCase):
    def run_now(self, queue, path, pos):
        pm = load_helper()
        props = {"playlist-pos": pos, "path": path, "metadata": {}, "pause": False,
                 "time-pos": 12.0, "duration": 293.0, "volume": 80, "playlist-count": 3,
                 "loop-playlist": "no", "media-title": ""}
        args = mock.Mock(no_fetch=True)
        out = io.StringIO()
        with mock.patch.object(pm, "mpv_running", return_value=True), \
                mock.patch.object(pm, "mpv_get", side_effect=lambda p: props.get(p)), \
                mock.patch.object(pm, "read_json", return_value=queue), \
                redirect_stdout(out):
            pm.cmd_now(args)
        return json.loads(out.getvalue())

    def test_now_reports_the_playing_album_and_artist(self):
        d = self.run_now(QUEUE, "http://h/library/parts/801/file.flac", 0)
        self.assertEqual((d["albumKey"], d["artistKey"], d["albumYear"]), ("600", "91", 2005))
        self.assertEqual(d["album"], "album 600")

    def test_old_queue_without_new_keys_gives_empty_strings(self):
        old = {"shuffle": False, "tracks": [{"key": "1", "title": "x", "albumKey": "5",
                                              "part": "/library/parts/9/f"}]}
        d = self.run_now(old, "http://h/library/parts/9/f", 0)
        self.assertEqual((d["albumKey"], d["artistKey"], d["albumYear"]), ("5", "", 0))

    def test_unknown_track_gives_no_keys(self):
        d = self.run_now(dict(QUEUE, shuffle=True), "http://h/elsewhere", 1)
        self.assertEqual((d["albumKey"], d["artistKey"]), ("", ""))


class PanelWiringTest(unittest.TestCase):
    def setUp(self):
        self.panel = open(os.path.join(REPO, "Panel.qml"), encoding="utf-8").read()
        self.service = open(os.path.join(REPO, "Service.qml"), encoding="utf-8").read()

    def body(self, text, name):
        m = re.search(r"function %s\(\)\s*\{" % name, text)
        self.assertIsNotNone(m, f"{name}() missing")
        depth, i = 1, m.end()
        while depth:
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        return text[m.end():i]

    def test_reveal_goes_by_keys_not_by_name(self):
        body = self.body(self.service, "revealPlaying")
        self.assertIn("trackAlbumKey", body)
        self.assertIn("trackArtistKey", body)
        self.assertNotRegex(body, r"\bsearch\(")

    def test_now_playing_line_and_ctrl_g_call_go_to_playing(self):
        self.assertGreaterEqual(len(re.findall(r"TapHandler\s*\{[^}]*root\.goToPlaying\(\)", self.panel)), 2)
        self.assertRegex(self.panel, r"case Qt\.Key_G:\s*\n\s*if \(event\.modifiers & Qt\.ControlModifier\) \{ root\.goToPlaying\(\)")
        self.assertIn("service.revealPlaying()", self.body(self.panel, "goToPlaying"))


if __name__ == "__main__":
    unittest.main()
