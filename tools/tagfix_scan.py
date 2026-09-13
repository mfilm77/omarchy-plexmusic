#!/usr/bin/env python3
"""Inventory of badly-titled tracks in a Plex music library. READ-ONLY.

Finds tracks whose title is a placeholder ("Track 03", "Audio Track 7",
"Unknown", a bare number) and writes them out with everything Plex knows that
can identify them: folder artist, folder album, disc/track number, duration,
file path. This is the input to the MusicBrainz matcher.
"""
import json, os, re, sys, urllib.request, urllib.parse

AUTH = os.path.expanduser("~/.config/omarchy-plex-music/auth.json")
SETTINGS = os.path.expanduser("~/.config/omarchy-plex-music/settings.json")
OUT = sys.argv[1] if len(sys.argv) > 1 else "bad_tracks.json"

token = json.load(open(AUTH))["authToken"]
st = json.load(open(SETTINGS))
base = st["baseUrl"]; section = st.get("musicSection", "31")

PLACEHOLDER = re.compile(
    r"^\s*(?:(?:audio\s*)?track\s*[-_ ]?\d{1,3}|\d{1,3}(?:\s*[-._]\s*)?(?:track)?|"
    r"unknown(?:\s*(?:track|title|song))?|untitled(?:\s*\d*)?|no\s*title|pista\s*\d+|"
    r"faixa\s*\d+|piste\s*\d+|titre\s*\d+|spur\s*\d+|traccia\s*\d+|new\s*track)\s*$",
    re.I)

def get(path, params=None):
    url = base + path
    if params: url += ("&" if "?" in path else "?") + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"X-Plex-Token": token, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode("utf-8", "replace"))

bad = []; total = 0; start = 0; page = 5000
while True:
    d = get(f"/library/sections/{section}/all", {"type": 10, "X-Plex-Container-Start": start,
                                                  "X-Plex-Container-Size": page})
    mc = d["MediaContainer"]; items = mc.get("Metadata") or []
    for m in items:
        total += 1
        title = m.get("title") or ""
        if not (title.strip() == "" or PLACEHOLDER.match(title)):
            continue
        part = ((m.get("Media") or [{}])[0].get("Part") or [{}])[0]
        bad.append({
            "key": str(m.get("ratingKey")), "title": title,
            "artist": m.get("grandparentTitle") or "", "album": m.get("parentTitle") or "",
            "albumKey": str(m.get("parentRatingKey") or ""), "artistKey": str(m.get("grandparentRatingKey") or ""),
            "disc": m.get("parentIndex") or 1, "index": m.get("index") or 0,
            "year": m.get("parentYear") or m.get("year") or 0,
            "duration_ms": int(m.get("duration") or 0),
            "file": part.get("file") or "", "container": part.get("container") or "",
        })
    start += len(items)
    if not items or start >= mc.get("totalSize", 0): break

json.dump({"total_tracks": total, "bad": bad}, open(OUT, "w"), indent=1, ensure_ascii=False)
albums = {}
for b in bad: albums.setdefault((b["artist"], b["album"]), []).append(b)
print(f"scanned {total} tracks; {len(bad)} placeholder-titled across {len(albums)} albums")
print("top albums by bad-track count:")
for (a, al), lst in sorted(albums.items(), key=lambda kv: -len(kv[1]))[:12]:
    print(f"  {len(lst):3d}  {a} — {al}")
