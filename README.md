# Plex Music

Play your own music library from the Omarchy bar.

A turntable with the real album cover on the label, a full-width spectrum
analyser in your theme's colours, your starred artists one click away, the
whole library browsable A–Z, and type-to-search across all of it. A small live
meter sits beside the track in the bar while music plays. Tracks come straight
off your Plex server through mpv — direct play, no transcode, no Plex Pass,
nothing via the cloud.

![Plex Music](preview.png)

## What is in the panel

- **Starred** — the artists you keep. Star any artist to add them.
- **All artists** — the whole library A–Z with a jump strip.
- **Playlists** — your Plex playlists (the real ones; they show up in every
  other Plex app).
- Open an artist for their **albums** (covers, years), an album for its
  **tracks**. Every row has play; clicking a track plays the album from there.
- The **+** on a track, an album, or "Add all" opens *Add to playlist*: pick an
  existing playlist or type a name to start a new one. The plugin only ever
  adds — it never removes tracks or deletes playlists.

Keyboard, with the cursor in the search box the whole time:

| Key | Does |
| --- | --- |
| type | search artists |
| ↑ ↓ / PgUp PgDn | move the highlight |
| Enter | open the highlighted row (artist → albums → tracks); on a track, play from it |
| Ctrl+Enter | play the highlighted row |
| ← / Backspace (empty box) | back |
| Ctrl+P | add the highlighted track or album to a playlist |
| Esc | close the popup, clear the search, go back, then close the panel |

## Why this rather than the other Plex plugins

The Plex plugins on the marketplace either monitor the server or play video.
This one is for a music library you already own: a list of the artists you
actually reach for, a search box over everything else, and one click to play.

## Requirements

- [Omarchy](https://omarchy.org/) (Quattro / shell plugins)
- A Plex Media Server with a music library
- `mpv` — the player
- `mpv-mpris` — so the rest of the desktop sees what is playing (optional)
- `cava` — the spectrum analyser (optional; without it the band says "idle")

```bash
sudo pacman -S mpv mpv-mpris cava
```

## Install

```bash
omarchy plugin add https://github.com/mfilm77/omarchy-plexmusic.git --enable
```

Then click the widget and link your Plex account: it shows a four-character
code, you type it at [plex.tv/link](https://plex.tv/link), done.

## Remove

```bash
omarchy plugin remove io.github.mfilm77.plexmusic
```

To disable it but keep the files:

```bash
omarchy plugin disable io.github.mfilm77.plexmusic
```

## How it finds your server

In this order:

1. **Addresses you added yourself.** This is the one that matters if your server
   is only reachable over a VPN — Plex does not advertise a Tailscale or
   WireGuard address, so you tell the plugin about it:

   ```bash
   .../bin/plexmusic server --add http://100.64.0.10:32400
   ```

2. **Whatever plex.tv reports** for your account — local addresses first, then
   remote, with Plex's relay last because it is slow.

Every candidate is probed before use, so a laptop that moves between the LAN and
a VPN picks the reachable one each time without being told. `plexmusic server`
lists them all with round-trip times.

## Your credentials

- Linking uses the **plex.tv PIN flow**: your password is typed into Plex's own
  site, never into this plugin. Plex hands back a token.
- That token is written to `~/.config/omarchy-plex-music/auth.json`, mode
  `0600`, on the machine you linked. It is never sent anywhere but your own
  Plex server.
- `plexmusic link forget` deletes the token, the server settings and the cached
  index.
- Nothing credential-shaped is in this repository, and the files that hold a
  token are in `.gitignore`.

Two files are also `0600` because they embed the token in stream URLs: the
generated queue (`~/.local/share/omarchy-plex-music/queue.m3u`) and its metadata.

## Keyboard shortcuts and macropads

Bind keys straight to the helper — it needs no running shell:

```bash
.../plugins/io.github.mfilm77.plexmusic/bin/plexmusic cmd play-pause
.../plugins/io.github.mfilm77.plexmusic/bin/plexmusic cmd next
```

Middle-clicking the bar widget also toggles play/pause without opening anything.

## The helper on its own

`bin/plexmusic` is a plain Python script that prints JSON, so it is usable and
testable without the shell:

| Command | What it does |
| --- | --- |
| `link start` / `link poll` | the plex.tv code flow |
| `link forget` | delete the token and all local state |
| `server` / `server --add URL` | list or add server addresses |
| `index` | build the artist index (a few seconds for thousands of artists) |
| `search QUERY` | match artists, accent- and case-insensitively |
| `favourites list\|add\|remove\|move` | the starred list |
| `albums --artist KEY` | an artist's albums, newest first |
| `tracks --album KEY` / `--playlist KEY` / `--artist KEY` | track listings |
| `playlists list` / `create --title T --tracks k1,k2` / `add --key P --tracks k1,k2` | Plex playlists (add-only, never delete) |
| `play --key ARTIST` / `--album KEY` / `--playlist KEY` / `--tracks k1,k2` `[--start-at K] [--shuffle]` | play |
| `cmd play-pause\|next\|prev\|stop\|volume` | transport |
| `now` | what is playing, with the cached cover's path |
| `art THUMB` | cache a cover and print its local path |

`PLEXMUSIC_MPV_ARGS` is passed through to mpv, for picking an output device or
changing the replaygain mode.

## How it works

- **Artists** are indexed once into `~/.local/share/omarchy-plex-music`. The
  panel loads that file into memory and searches it in QML, so typing never
  waits on a process; the A–Z list is a virtualised view over the same array,
  so thousands of artists scroll and jump without loading anything. The index
  is in Plex's own sort order, which files "The Beatles" under B.
- **Bar widget settings**: `showTrack`, `maxTrackChars`, `showMeter` and
  `meterBars` (the bar meter folds the 64 cava bands down to that many; the
  panel always shows all 64). The bar meter only appears while music is
  sounding, and cava only runs then or while the panel is open.
- **Playback** is an m3u of direct-play URLs handed to mpv, which is controlled
  over an IPC socket. ReplayGain is on, which evens out a library ripped over
  twenty years; it is a no-op on files with no tags.
- **The current track** is found by matching mpv's path back to the queue, not
  by playlist index, so it stays correct when shuffle reorders things.
- **Covers** come from Plex's own photo transcoder at 500 px and are cached in
  `~/.cache/omarchy-plex-music/art`. The cache key includes Plex's artwork
  version, so replacing a cover in Plex does not leave a stale one here.
- **The record** turns at 33⅓ rpm — 1.8 s a revolution. Pausing stops it where
  it is.
- **The meters** are `cava` in raw mode, read a frame at a time. cava taps the
  default output's monitor, so the band follows whatever the machine is playing
  and keeps working when you switch to headphones. It only runs while the panel
  is open.
- **Colours** are read from the active Omarchy theme — quiet passages in the
  accent colour, peaks in the urgent colour, caps in the foreground colour. No
  hardcoded palette.

## Non-obvious bits

- **Mangled characters in artist names.** Plex hands back whatever bytes are in
  the file tags, and an old library has tags that are not valid UTF-8. Those
  bytes are replaced rather than allowed to fail the whole index.
- **Editing an open panel.** Omarchy hot-reloads a changed plugin, but a panel
  that has already been opened keeps its compiled instance until the shell is
  restarted (`omarchy-restart-shell` — *not* `omarchy-refresh-shell`, which
  resets your whole bar layout). Bar widgets and the service do reload live.
- **Play counts are not used.** On a large library Plex can report an identical
  `viewCount` for every artist, which makes "most played" meaningless. The
  starred list is curated by you for that reason.

## License

MIT. See [LICENSE](LICENSE).
