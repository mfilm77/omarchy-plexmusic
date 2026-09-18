# Changelog

## 0.2.0

### Fixed

- **The library stayed empty after a first run.** Linking the Plex account and
  *then* adding the server — the order the settings page invites — left the
  plugin linked, reachable and correctly configured with nothing in it. The
  index attempt that fires after linking had no address yet and gave up, and
  adding an address afterwards never chose a music library or tried again.
  Pinning a reachable server now picks the music library and indexes straight
  away, and an install that is already stuck in that state repairs itself the
  next time the panel opens.
- **Rescan looked like it did nothing.** A full index of a large library takes
  minutes and writes nothing to watch while it runs, and the view a new user
  lands on — favourites, necessarily empty — said only "tap the star on any
  artist". It now says the index is running, wherever the panel would otherwise
  claim the library is simply empty, and a toast marks the start and the end
  with the counts.
- **A failed index said nothing at all.** Any reason indexing cannot start or
  cannot finish is now shown in the panel rather than stored and forgotten — no
  server, no account, a helper that dies without a word. Failures are also
  appended to `~/.cache/omarchy-plex-music/plexmusic.log` (the last 200 lines,
  owner-only, with any token redacted), so a bad run leaves a trace even when
  nobody was looking at the panel.
- **The Rescan button could lock itself out.** An indexer that was killed, or
  that exited without printing anything, left the panel saying "indexing" for
  ever with the button disabled until the shell was restarted.
- **The record stopped turning while the music played** (0.1.0 regression). The
  spin was a render-thread `RotationAnimator`, and hiding the kept-loaded panel
  killed its job while the binding still said it was running. It is now a
  `NumberAnimation` bound to both playback and visibility.

### Added

- **Tap what is playing to open its album.** The title and artist · album line
  under the record is a tap target, and `Ctrl+G` does the same. It navigates by
  Plex key, never by searching for a name, and leaves the artist's discography
  behind it so Back lands somewhere useful. A track with no album opens the
  artist instead.
- `index` reports how many tracks Plex said it held and how many were skipped
  for having no title at all, so a gap between the two is visible.

### Security

Both findings from the Omarchy marketplace security review of `0c0c813`
(HANCORE-linux, 2026-09-17) are fixed. Thanks for the report.

- **Every file is written through a verified private directory.** Each JSON
  file went through a predictable `path + ".tmp"` opened normally, so a symlink
  planted at that name was followed and its target truncated — and those files
  include `auth.json`, which holds the Plex token, and the queue whose URLs
  carry it. The state directory is now opened `O_NOFOLLOW` and checked with
  `fstat` (a directory, owned by you, 0700 enforced); the temporary file is
  created relative to that descriptor with an unpredictable name and
  `O_CREAT|O_EXCL|O_NOFOLLOW` at 0600; the descriptor is re-checked before a
  byte is written; the data is `fsync`ed, renamed atomically through the
  directory descriptor, and the directory is `fsync`ed after. The settings, the
  favourites, the indexes, the queue, the m3u playlist, the artwork cache and
  the new failure log all use it — there is no other write path in the program.
  A **symlinked** config or data directory is now refused rather than written
  through.
- **Every network reply is capped before it is buffered.** Plex JSON and
  artwork were read to EOF with no limit, and the persistent shell then read
  whole generated indexes. An over-limit `Content-Length` is now refused before
  the body is read, and the limit is enforced again while streaming, so a
  chunked or dishonest server gets no further than the cap. JSON and artwork
  have separate limits. The index is bounded in item count and in per-string
  length as it is built, and the shell refuses an index file that is too large
  to parse or that holds too many items instead of loading it.

### Also

- The artwork cache directory is tightened to 0700 if an older version left it
  world-readable.

## 0.1.0

First release.
