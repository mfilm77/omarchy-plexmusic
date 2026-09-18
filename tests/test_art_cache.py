"""Covers reach the panel as local files, never as tokened Plex URLs.

Run from the repo root:  python3 -m unittest discover -s tests
Needs no Plex server: the network is replaced with a fake.
"""

import importlib.machinery
import importlib.util
import json
import os
import stat
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "bin", "plexmusic")

TOKEN = "SECRET-TEST-TOKEN-123"
JPEG = b"\xff\xd8\xff\xe0fake-jpeg-bytes"


def load_helper():
    loader = importlib.machinery.SourceFileLoader("plexmusic_helper", HELPER)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class FakeResponse:
    """Enough of an HTTP response for the capped reader: a Content-Length
    header and a read() that honours the size it is asked for."""

    def __init__(self, data):
        self.data = data
        self.pos = 0
        self.headers = {"Content-Length": str(len(data))}

    def read(self, n=-1):
        if n is None or n < 0:
            n = len(self.data) - self.pos
        out = self.data[self.pos:self.pos + n]
        self.pos += len(out)
        return out

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class ArtCacheTest(unittest.TestCase):
    def setUp(self):
        self.pm = load_helper()
        self.tmp = tempfile.TemporaryDirectory()
        self.pm.ART_DIR = os.path.join(self.tmp.name, "art")
        self.plex = self.pm.Plex.__new__(self.pm.Plex)
        self.plex.token = TOKEN
        self.plex.client_id = "test-client"
        self.plex.base = "http://plex.example:32400"
        self.plex.settings = {}
        self.plex.section = "1"
        self.requests = []

    def tearDown(self):
        self.tmp.cleanup()

    def fake_urlopen(self, data=JPEG, fail=False):
        def opener(req, timeout=None):
            self.requests.append(req)
            if fail:
                raise OSError("server went away")
            return FakeResponse(data)
        return mock.patch.object(self.pm.urllib.request, "urlopen", side_effect=opener)

    def test_cache_path_stays_in_cache_dir(self):
        for thumb in ["/library/metadata/12/thumb/1690000000",
                      "/../../etc/passwd", "..", "/a b?c=d&X-Plex-Token=x"]:
            path = self.pm.art_cache_path(thumb, 160)
            self.assertEqual(os.path.dirname(path), self.pm.ART_DIR, thumb)
            self.assertFalse(os.path.basename(path).startswith("."), thumb)
        # Same key as before the change for ordinary thumbs: the cache survives.
        self.assertEqual(
            os.path.basename(self.pm.art_cache_path("/library/metadata/12/thumb/169", 500)),
            "library_metadata_12_thumb_169_500.jpg")

    def test_attach_art_gives_file_urls_without_token(self):
        items = [{"thumb": "/library/metadata/1/thumb/9"},
                 {"thumb": "/library/metadata/1/thumb/9"},
                 {"thumb": "/library/metadata/2/thumb/9"},
                 {"thumb": ""}]
        with self.fake_urlopen():
            self.plex.attach_art(items, 160)
        dumped = json.dumps(items)
        self.assertNotIn(TOKEN, dumped)
        self.assertNotIn("X-Plex-Token", dumped)
        self.assertNotIn("http", dumped)
        for it in items[:3]:
            self.assertTrue(it["artUrl"].startswith("file://" + self.pm.ART_DIR))
        self.assertEqual(items[3]["artUrl"], "")
        # Two distinct covers, fetched once each.
        self.assertEqual(len(self.requests), 2)

    def test_token_only_in_header_not_url(self):
        with self.fake_urlopen():
            self.plex.attach_art([{"thumb": "/library/metadata/3/thumb/1"}], 96)
        (req,) = self.requests
        self.assertNotIn(TOKEN, req.full_url)
        self.assertEqual(req.get_header("X-plex-token"), TOKEN)

    def test_cached_file_is_owner_only_and_reused(self):
        items = [{"thumb": "/library/metadata/4/thumb/1"}]
        with self.fake_urlopen():
            self.plex.attach_art(items, 200)
        path = self.pm.art_cache_path(items[0]["thumb"], 200)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.pm.ART_DIR).st_mode) & 0o077, 0)
        with open(path, "rb") as fh:
            self.assertEqual(fh.read(), JPEG)
        self.requests.clear()
        with self.fake_urlopen(fail=True):
            again = [{"thumb": items[0]["thumb"]}]
            self.plex.attach_art(again, 200)
        self.assertEqual(self.requests, [])           # served from the cache
        self.assertEqual(again[0]["artUrl"], items[0]["artUrl"])

    def test_failed_fetch_gives_empty_url_and_no_leftovers(self):
        items = [{"albumThumb": "/library/metadata/5/thumb/1"}]
        with self.fake_urlopen(fail=True):
            self.plex.attach_art(items, 96, thumb_field="albumThumb")
        self.assertEqual(items[0]["artUrl"], "")
        # Nothing is written, and since the fetch happens before the file is
        # created the cache directory need not exist at all.
        self.assertEqual(
            os.listdir(self.pm.ART_DIR) if os.path.isdir(self.pm.ART_DIR) else [],
            [])

    def test_listings_carry_no_token(self):
        listing = {"MediaContainer": {"Metadata": [
            {"type": "album", "ratingKey": 7, "title": "A", "year": 1970,
             "leafCount": 9, "thumb": "/library/metadata/7/thumb/1"},
        ]}}
        playlists = {"MediaContainer": {"Metadata": [
            {"ratingKey": 8, "title": "P", "leafCount": 3, "duration": 1,
             "composite": "/playlists/8/composite/1"},
        ]}}
        with self.fake_urlopen(), \
                mock.patch.object(self.pm.Plex, "get",
                                  side_effect=[listing, playlists]):
            albums = self.plex.artist_albums("6")
            lists = self.plex.playlists()
        dumped = json.dumps([albums, lists])
        self.assertNotIn(TOKEN, dumped)
        self.assertTrue(albums[0]["artUrl"].startswith("file://"))
        self.assertTrue(lists[0]["artUrl"].startswith("file://"))


if __name__ == "__main__":
    unittest.main()
