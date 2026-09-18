import QtQuick
import Quickshell
import Quickshell.Io

// Always-loaded state for the plugin: what is playing, the whole artist index,
// the starred artists, search results, and the spectrum frame the meters draw.
//
// None of the Plex or mpv work happens here. It all goes through `bin/plexmusic`,
// which speaks JSON on stdout, because holding an HTTP session and an mpv IPC
// socket open from QML would put the whole shell at the mercy of a slow server.
// The one exception is search: the index is loaded into memory once and
// filtered here, so typing never waits on a process.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  // The shell copies the plugin somewhere of its own choosing, so the helper is
  // found relative to this file rather than guessed at.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    return u.indexOf("file://") === 0 ? u.substring(7) : u
  }
  readonly property string helper: pluginDir + "bin/plexmusic"
  readonly property string home: Quickshell.env("HOME")
  readonly property string indexPath: home + "/.local/share/omarchy-plex-music/artists.json"
  readonly property string trackIndexPath: home + "/.local/share/omarchy-plex-music/tracks.json"

  // ---- account + server ---------------------------------------------------
  property bool linked: false
  property string server: ""
  // The music library the helper is indexing, "" until one is chosen.
  property string section: ""
  property string lastError: ""
  property string linkCode: ""
  property bool linking: false
  property bool indexing: false
  // Whether the running index process has printed its JSON yet, so a helper
  // that dies silently can still be reported once.
  property bool indexReplied: false
  // Live progress of a running scan, polled from the helper. A big library
  // takes minutes, and a number that climbs is the difference between "it is
  // working" and "this button does nothing".
  property int indexArtists: 0
  property int indexTracks: 0
  property int indexTrackTotal: 0
  property string indexStage: ""          // "artists", "tracks", "done"
  property int indexElapsed: 0            // seconds since the scan started

  // One line for any view to show: what the scan is doing, with its counts.
  readonly property string indexProgress: {
    if (!indexing) return ""
    var bits = []
    if (indexArtists > 0) bits.push(indexArtists.toLocaleString() + " artists")
    if (indexTracks > 0)
      bits.push(indexTrackTotal > 0
        ? indexTracks.toLocaleString() + " of " + indexTrackTotal.toLocaleString() + " songs"
        : indexTracks.toLocaleString() + " songs")
    var head = bits.length > 0 ? "Scanning your library — " + bits.join(" · ")
                               : "Scanning your library…"
    if (indexElapsed > 0) {
      var m = Math.floor(indexElapsed / 60)
      var sec = indexElapsed % 60
      head += "  (" + m + ":" + (sec < 10 ? "0" : "") + sec + ")"
    }
    return head
  }
  // One shot per session: an install that is linked, has a server, and still
  // has no index gets one automatic attempt when the panel first sees it.
  // That is what repairs the machines already stuck in the first-run trap.
  property bool firstIndexTried: false

  // ---- library ------------------------------------------------------------
  // Every artist, in Plex's own sort order (which files "The Beatles" under B).
  // Each has key, title, fold (search key), letter (A-Z or #).
  property var artists: []
  readonly property int artistCount: artists.length
  // First index of each letter, for the A-Z jump strip.
  property var letterIndex: ({})
  property var favourites: []
  property var searchResults: []          // artists matching the query
  property var trackResults: []           // songs matching the query
  // One list for the search view: artist rows then song rows, each tagged.
  property var searchItems: []
  property string query: ""
  // Every track, slim, in Plex's title order: key, title, artist, album,
  // albumKey, duration, fold, letter.
  property var allTracks: []
  readonly property int trackCount: allTracks.length
  property var trackLetterIndex: ({})

  // ---- browsing -----------------------------------------------------------
  // What the right-hand column is showing: "artists" (starred, all, or search
  // results), "albums" of the chosen artist, "tracks" of an album or playlist,
  // or "playlists". Kept here rather than in the panel so closing and
  // reopening lands you where you were.
  property string view: "artists"
  property bool browseAll: false
  property var selectedArtist: null     // {key, title}
  property var selectedAlbum: null      // {key, title, year, artUrl, ...}
  property var selectedPlaylist: null   // {key, title, tracks}
  property var albums: []
  property var tracks: []
  property var playlists: []
  property bool loadingAlbums: false
  property bool loadingTracks: false
  property bool loadingPlaylists: false
  // The add-to-playlist flow: which track keys are waiting to be added.
  property var pendingAdd: []
  property bool addOpen: false
  property bool addBusy: false
  property string toast: ""

  // ---- stations -----------------------------------------------------------
  // Radio built client-side from the server's filters, as Plexamp does.
  property var stationDecades: []      // [{decade, label, albums}]
  property var stationStyles: []       // [{key, title}]
  property var stationMoods: []
  property var decadeRows: []          // [{decade, label, albums:[...]}]
  property bool stationsLoaded: false
  property bool loadingStations: false
  property real stationsAt: 0          // when the decade rows were last fetched
  property string stationPick: ""      // "", "decade", "style", "mood"

  // ---- settings -----------------------------------------------------------
  property var servers: []            // from `server`: uri, source, reachable, ms
  property bool loadingServers: false
  property var account: ({})          // {username, valid}
  property var sections: []           // music libraries on the server
  property bool settingsBusy: false
  property string settingsNote: ""

  // ---- playback -----------------------------------------------------------
  property bool playing: false
  property bool paused: false
  property string trackTitle: ""
  property string trackArtist: ""
  property string trackAlbum: ""
  property string artPath: ""
  property string trackKey: ""           // Plex key of the playing track
  property string trackAlbumKey: ""
  property string trackArtistKey: ""
  property int trackAlbumYear: 0
  property real position: 0
  property real duration: 0
  property int queuePos: 0
  property int queueCount: 0
  property bool queueShuffled: false     // whether what is playing was started shuffled
  property bool shuffle: true
  property bool loop: false               // repeat the queue when it ends
  property real volume: 100

  // ---- spectrum -----------------------------------------------------------
  // One frame of cava's raw output: 64 values, each 0-100.
  property var levels: []
  // The panel asks for the meters while it is open; the bar's mini meter
  // wants them whenever music is actually sounding. cava runs if either does.
  property bool spectrumWanted: false
  readonly property bool cavaWanted: spectrumWanted || (playing && !paused)

  readonly property string label: {
    if (!playing) return "Plex Music"
    if (trackTitle && trackArtist) return trackTitle + " — " + trackArtist
    return trackTitle || trackAlbum || "Plex Music"
  }

  // Ceilings on anything we load from disk. The index files are written by
  // our own helper, but they are built from whatever a Plex server says, so
  // the shell treats them as untrusted: an index that is too big to be real
  // is refused outright rather than parsed and published, because everything
  // here lives in the persistent Quickshell process.
  //
  // Sized off the largest real library this has run against (66,626 tracks /
  // 5,167 artists) with room for one four times bigger, and matching
  // MAX_INDEX_ITEMS / MAX_FIELD_CHARS in bin/plexmusic. Its track index is
  // 20 MB on disk (60,002 tracks, ~340 bytes each), so 96 MB is ~5x the real
  // file and is also what maxIndexItems entries of that size would weigh.
  readonly property int maxIndexItems: 250000
  readonly property int maxFieldChars: 512
  readonly property int maxIndexBytes: 96 * 1024 * 1024
  // A progress record is a handful of numbers and one short word. Anything
  // bigger than this is not a progress record, whatever it claims to be.
  readonly property int maxProgressBytes: 4096
  readonly property int maxStageChars: 32
  // Set when an index was refused, so the panel can say why instead of
  // silently showing an empty library.
  property string indexError: ""

  function parse(text) {
    try { return JSON.parse(text) } catch (e) { return null }
  }

  // Parse an index file, or return null and set indexError. `text` is checked
  // for length before it is parsed, so an absurd file never becomes objects.
  function parseIndex(text, what) {
    var s = String(text || "")
    if (s.length > root.maxIndexBytes) {
      root.indexError = what + " index is too large (" + s.length
        + " bytes) — refusing to load it"
      console.warn("plexmusic:", root.indexError)
      return null
    }
    var d = root.parse(s)
    if (d === null && s !== "") {
      root.indexError = "the " + what + " index file is not readable JSON"
      console.warn("plexmusic:", root.indexError)
    }
    return d
  }

  // Refuse an over-long list, and clamp the strings inside the ones we keep.
  // `null` in means the file was already refused by parseIndex — pass that
  // refusal straight through, or the caller would replace a good index with an
  // empty one and this function's success path would wipe the reason with it.
  function boundedIndexList(list, what) {
    if (list === null) return null
    if (!list || list.length === undefined) return []
    if (list.length > root.maxIndexItems) {
      root.indexError = what + " index holds " + list.length
        + " items, over the " + root.maxIndexItems + " limit — refusing it"
      console.warn("plexmusic:", root.indexError)
      return null
    }
    for (var i = 0; i < list.length; i++) {
      var it = list[i]
      if (!it) continue
      var keys = ["title", "artist", "album", "fold", "thumb", "key",
                  "albumKey", "artistKey", "letter"]
      for (var k = 0; k < keys.length; k++) {
        var v = it[keys[k]]
        if (typeof v === "string" && v.length > root.maxFieldChars)
          it[keys[k]] = v.substring(0, root.maxFieldChars)
      }
    }
    root.indexError = ""
    return list
  }

  // Lower-case, accents stripped, matching the helper's fold(). Used only on
  // the typed query; the index arrives pre-folded.
  function fold(s) {
    s = String(s || "").toLowerCase()
    try { s = s.normalize("NFD").replace(/[\u0300-\u036f]/g, "") } catch (e) {}
    return s
  }

  // ---- the index ----------------------------------------------------------

  // ⚠️ A FileView can only be trusted for a file that already existed when it
  // was constructed. On a fresh install neither index file is there when the
  // shell starts, so the load fails and no watch is ever attached — which is
  // why a first-time user used to stay at an empty panel until they restarted
  // the shell. Anything the helper creates must be re-read explicitly once the
  // helper says it is there: see reloadIndexFiles().
  FileView {
    id: indexFile
    path: root.indexPath
    watchChanges: true
    onLoaded: root.applyIndex()
    onFileChanged: reload()
    onLoadFailed: function (error) {
      // Absent before the first index is normal and not worth a message.
      if (root.artistCount > 0)
        root.indexError = "the artist index could not be read"
    }
  }

  FileView {
    id: trackIndexFile
    path: root.trackIndexPath
    watchChanges: true
    onLoaded: root.applyTrackIndex()
    onFileChanged: reload()
    onLoadFailed: function (error) {
      if (root.trackCount > 0)
        root.indexError = "the song index could not be read"
    }
  }

  // Re-read both index files from scratch. Re-assigning `path` re-runs the
  // load AND attaches the watcher, which a bare reload() on a FileView that
  // never managed to load does not.
  // Note this replaces the declarative `path:` binding with a static value.
  // That is deliberate and safe here — indexPath is derived from $HOME and
  // never changes — but anything that later makes those paths dynamic has to
  // revisit this.
  function reloadIndexFiles() {
    indexFile.path = ""
    indexFile.path = root.indexPath
    trackIndexFile.path = ""
    trackIndexFile.path = root.trackIndexPath
  }

  function applyTrackIndex() {
    var d = root.parseIndex(trackIndexFile.text(), "track")
    // Refused or unreadable: keep whatever index we already had, and keep the
    // reason parseIndex recorded, rather than blanking the library.
    if (d === null) return
    var list = root.boundedIndexList(d.tracks ? d.tracks : [], "track")
    if (list === null) return
    var idx = {}
    for (var i = 0; i < list.length; i++) {
      var l = list[i].letter || "#"
      if (idx[l] === undefined) idx[l] = i
    }
    root.allTracks = list
    root.trackLetterIndex = idx
    if (root.query !== "") root.search(root.query)
  }

  function applyIndex() {
    var d = root.parseIndex(indexFile.text(), "artist")
    if (d === null) return
    var list = root.boundedIndexList(d.artists ? d.artists : [], "artist")
    if (list === null) return
    var idx = {}
    for (var i = 0; i < list.length; i++) {
      var l = list[i].letter || "#"
      if (idx[l] === undefined) idx[l] = i
    }
    root.artists = list
    root.letterIndex = idx
    if (root.query !== "") root.search(root.query)
  }

  function search(text) {
    root.query = text || ""
    var q = fold(root.query.trim())
    if (q === "") { root.searchResults = []; root.trackResults = []; root.searchItems = []; return }
    var starts = [], contains = []
    var list = root.artists
    for (var i = 0; i < list.length; i++) {
      var k = list[i].fold || fold(list[i].title)
      if (k.indexOf(q) === 0) starts.push(list[i])
      else if (k.indexOf(q) >= 0) contains.push(list[i])
      if (starts.length >= 40) break
    }
    root.searchResults = starts.concat(contains).slice(0, 40)

    // Songs: prefix matches first, then anywhere in the title, capped so a
    // one-letter query does not build a 60,000-row list.
    var ts = [], tc = []
    var tl = root.allTracks
    for (var j = 0; j < tl.length; j++) {
      var tk = tl[j].fold
      if (tk.indexOf(q) === 0) ts.push(tl[j])
      else if (tc.length < 80 && tk.indexOf(q) >= 0) tc.push(tl[j])
      if (ts.length >= 80) break
    }
    root.trackResults = ts.concat(tc).slice(0, 80)

    var items = []
    for (var a = 0; a < root.searchResults.length; a++)
      items.push({ kind: "artist", key: root.searchResults[a].key, title: root.searchResults[a].title })
    for (var t = 0; t < root.trackResults.length; t++) {
      var tr = root.trackResults[t]
      items.push({ kind: "track", key: tr.key, title: tr.title, artist: tr.artist, album: tr.album,
                   albumKey: tr.albumKey, artistKey: tr.artistKey, duration: tr.duration })
    }
    root.searchItems = items
  }

  // ---- helper calls -------------------------------------------------------

  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        var d = root.parse(text)
        if (!d) return
        root.linked = !!d.linked
        root.server = d.server || ""
        root.section = d.section ? String(d.section) : ""
        // Already set up but never indexed — the state every machine that hit
        // the first-run trap is sitting in. Try once per session, so an empty
        // Plex library does not turn into an indexing loop.
        if (d.linked && root.server && !root.firstIndexTried && !root.indexing
            && !d.indexedAt && root.artistCount === 0) {
          root.firstIndexTried = true
          Qt.callLater(function () { root.reindex() })
        }
        // The library was scanned since we indexed it: rebuild quietly, so
        // anything added to Plex appears here without a manual rescan.
        if (d.linked && d.libraryScannedAt && d.indexedAt && d.libraryScannedAt > d.indexedAt
            && !root.indexing && (Date.now() - root.lastAutoIndex) > 600000) {
          root.lastAutoIndex = Date.now()
          root.reindex()
          root.stationsLoaded = false
        }
      }
    }
  }
  property real lastAutoIndex: 0

  Process {
    id: favProc
    stdout: StdioCollector {
      onStreamFinished: {
        var d = root.parse(text)
        if (d && d.items) root.favourites = d.items
      }
    }
  }

  // While a play command is in flight mpv is stopped and relaunched, and a
  // poll landing in that gap would report "not playing" — which lifted the
  // arm and dropped it again. Hold the playing state through the start.
  property bool playStarting: false
  Timer { id: startGuard; interval: 5000; onTriggered: root.playStarting = false }

  Process {
    id: playProc
    onRunningChanged: if (running) { root.playStarting = true; startGuard.restart() }
    stdout: StdioCollector {
      onStreamFinished: {
        var d = root.parse(text)
        root.lastError = (d && d.ok === false) ? (d.error || "could not play that") : ""
        if (d && d.ok === false) root.playStarting = false
        root.refreshNow()
      }
    }
  }

  Process {
    id: cmdProc
    stdout: StdioCollector { onStreamFinished: root.refreshNow() }
  }

  Process {
    id: nowProc
    command: [root.helper, "now"]
    stdout: StdioCollector {
      onStreamFinished: {
        var d = root.parse(text)
        if (!d) return
        if (!d.playing && root.playStarting) return      // mid-relaunch: keep what we had
        if (d.playing) root.playStarting = false
        root.playing = !!d.playing
        if (!d.playing) {
          root.trackKey = ""; root.trackAlbumKey = ""
          root.trackArtistKey = ""; root.trackAlbumYear = 0
          root.trackTitle = ""; root.trackArtist = ""; root.trackAlbum = ""
          root.artPath = ""; root.position = 0; root.duration = 0
          root.queuePos = 0; root.queueCount = 0
          return
        }
        root.paused = !!d.paused
        root.trackTitle = d.title || ""
        root.trackArtist = d.artist || ""
        root.trackAlbum = d.album || ""
        root.artPath = d.art || ""
        root.trackKey = d.key ? String(d.key) : ""
        root.trackAlbumKey = d.albumKey ? String(d.albumKey) : ""
        root.trackArtistKey = d.artistKey ? String(d.artistKey) : ""
        root.trackAlbumYear = d.albumYear || 0
        root.position = d.position || 0
        root.duration = d.duration || 0
        root.queuePos = (d.playlistPos || 0) + 1
        root.queueCount = d.playlistCount || 0
        root.queueShuffled = !!d.shuffle
        if (typeof d.loop === "boolean") root.loop = d.loop
        // Only trust mpv's volume once nothing of ours is still in flight.
        if (typeof d.volume === "number" && !root.volumeDragging
            && root.pendingVolume < 0 && !volProc.running) root.volume = d.volume
      }
    }
  }

  Process {
    id: indexProc
    command: [root.helper, "index"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.indexReplied = true
        root.indexing = false
        var d = root.parse(text)
        if (!d)
          root.indexError = "the indexer answered with nothing"
        else if (d.ok === false)
          root.indexError = d.error || "could not index the library"
        else
          root.indexError = ""
        if (root.indexError !== "") {
          root.lastError = root.indexError
          root.showToast("Indexing failed: " + root.indexError)
        } else if (d) {
          root.indexArtists = d.artistCount || 0
          root.indexTracks = d.trackCount || 0
          root.showToast((d.artistCount || 0) + " artists, "
            + (d.trackCount || 0) + " songs indexed")
        }
        // The panel reloads itself the moment the scan ends. Never leave this
        // to the file watcher: on a first index the files did not exist when
        // these readers were built, so there is no watch to fire.
        root.reloadIndexFiles()
        root.refreshStatus()
      }
    }
  }

  Connections {
    target: indexProc
    // Safety net. A helper that dies without printing its JSON — a traceback
    // on stderr, a missing python3 — used to leave the panel saying "Indexing
    // the library…" for ever, with Rescan disabled and nothing to read. Now
    // the panel says what happened and the button comes back.
    function onExited(exitCode, exitStatus) {
      if (root.indexReplied) return
      root.indexing = false
      root.indexError = exitCode === 0
        ? "the indexer stopped without indexing anything"
        : "the indexer failed (exit " + exitCode + ")"
      root.lastError = root.indexError
      root.showToast("Indexing failed: " + root.indexError)
      // It may still have written one of the two files before it died.
      root.reloadIndexFiles()
      root.refreshStatus()
    }
  }

  // While a scan runs, ask the helper how far it has got. `progress` reads one
  // small file and never touches Plex, so polling it is free next to the scan
  // itself. This is what makes the counts climb in every view.
  Process {
    id: progressProc
    command: [root.helper, "progress"]
    stdout: StdioCollector {
      onStreamFinished: {
        // The helper bounds this record, but the shell bounds it again: this
        // is the one thing a running scan tells the panel, and it is read
        // straight into properties of a process that never restarts.
        if (String(text || "").length > root.maxProgressBytes) {
          console.warn("plexmusic: refusing an oversized progress record")
          return
        }
        var d = root.parse(text)
        if (!d || d.ok === false) return
        // A scan started by something else — most often one that survived a
        // shell restart. Adopt it rather than offering to start a second.
        if (d.running && !root.indexing) {
          root.indexing = true
          root.indexReplied = true      // not our process; nothing to report
        } else if (!d.running && root.indexing && !indexProc.running) {
          root.indexing = false
          root.reloadIndexFiles()
          root.refreshStatus()
        }
        root.indexArtists = d.artists || 0
        root.indexTracks = d.tracks || 0
        root.indexTrackTotal = d.trackTotal || 0
        root.indexStage = String(d.stage || "").substring(0, root.maxStageChars)
        root.indexElapsed = d.elapsed || 0
      }
    }
  }

  Timer {
    id: progressTimer
    running: root.indexing
    interval: 1500
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!progressProc.running) progressProc.running = true
  }

  Process {
    id: linkStartProc
    command: [root.helper, "link", "start"]
    stdout: StdioCollector {
      onStreamFinished: {
        var d = root.parse(text)
        if (d && d.code) {
          root.linkCode = d.code
          root.linking = true
          linkPollTimer.start()
        } else {
          root.lastError = (d && d.error) ? d.error : "Plex would not issue a code"
        }
      }
    }
  }

  Process {
    id: linkPollProc
    command: [root.helper, "link", "poll"]
    stdout: StdioCollector {
      onStreamFinished: {
        var d = root.parse(text)
        if (d && d.linked) {
          root.linking = false
          root.linkCode = ""
          linkPollTimer.stop()
          root.refreshStatus()
          // A fresh account has no index yet; build it straight away so the
          // first search is not an empty list.
          root.reindex()
        }
      }
    }
  }

  Process {
    id: cavaProc
    running: false
    // cava prints one frame per line: 64 values 0-100 separated by ';'. At 60
    // fps that is a line every 16 ms, so this parser stays cheap — no
    // allocation beyond the one array the meters bind to.
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        if (!line) return
        var parts = line.split(";")
        var out = []
        for (var i = 0; i < parts.length; i++) {
          if (parts[i] === "") continue
          var v = parseInt(parts[i], 10)
          out.push(isNaN(v) ? 0 : v)
        }
        if (out.length > 0) root.levels = out
      }
    }
  }

  // ---- public API ---------------------------------------------------------

  function refreshStatus() { statusProc.running = true }
  function refreshNow() { nowProc.running = true }
  function refreshFavourites() {
    favProc.command = [root.helper, "favourites", "list"]
    favProc.running = true
  }
  // Rebuild the index. Every reason it cannot start is written where the panel
  // shows it — a Rescan that does nothing and says nothing is the bug this
  // release fixes.
  function reindex() {
    if (root.indexing) return
    if (!root.linked) {
      root.indexError = "not linked to Plex yet — link the account in Settings"
      return
    }
    if (!root.server) {
      root.indexError = "no Plex server yet — add its address in Settings"
      return
    }
    root.indexError = ""
    root.indexReplied = false
    root.indexArtists = 0
    root.indexTracks = 0
    root.indexTrackTotal = 0
    root.indexStage = "starting"
    root.indexElapsed = 0
    root.indexing = true
    // A full library takes minutes and writes nothing to watch until it is
    // done, so say so out loud the moment the button is pressed.
    root.showToast("Indexing your library — this can take a few minutes")
    indexProc.running = true
  }

  function playArtist(key) {
    if (!key) return
    var args = [root.helper, "play", "--key", String(key)]
    if (root.shuffle) args.push("--shuffle")
    if (root.loop) args.push("--loop")
    playProc.command = args
    playProc.running = true
  }

  function control(action) {
    cmdProc.command = [root.helper, "cmd", action]
    cmdProc.running = true
  }

  // While the fader is being dragged the poll must not fight the hand.
  property bool volumeDragging: false
  // Last value wins: a drag fires far faster than a helper process runs, so
  // moves are queued one deep and the newest is sent when the previous lands.
  property real pendingVolume: -1

  function setVolume(value) {
    var v = Math.max(0, Math.min(100, Math.round(value)))
    root.volume = v
    root.pendingVolume = v
    root.flushVolume()
  }

  function flushVolume() {
    if (volProc.running || root.pendingVolume < 0) return
    var v = root.pendingVolume
    root.pendingVolume = -1
    volProc.command = [root.helper, "cmd", "volume", "--value", String(v)]
    volProc.running = true
  }

  function seek(seconds) {
    if (!root.playing) return
    root.position = Math.max(0, Math.min(root.duration, seconds))
    cmdProc.command = [root.helper, "cmd", "seek", "--value", String(root.position)]
    cmdProc.running = true
  }

  // Its own process so a run of fader moves never cancels a transport command.
  Process {
    id: volProc
    onExited: root.flushVolume()
  }

  function isFavourite(key) {
    var k = String(key)
    for (var i = 0; i < favourites.length; i++)
      if (String(favourites[i].key) === k) return true
    return false
  }

  function toggleFavourite(key, title) {
    var fav = isFavourite(key)
    var args = [root.helper, "favourites", fav ? "remove" : "add", "--key", String(key)]
    if (!fav && title) { args.push("--title"); args.push(String(title)) }
    favProc.command = args
    favProc.running = true
  }

  function startLink() {
    root.lastError = ""
    linkStartProc.running = true
  }

  function cancelLink() {
    root.linking = false
    root.linkCode = ""
    linkPollTimer.stop()
  }

  // ---- browsing -----------------------------------------------------------

  Process {
    id: albumsProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.loadingAlbums = false
        var d = root.parse(text)
        if (d && d.albums) root.albums = d.albums
        else root.lastError = (d && d.error) ? d.error : "could not load albums"
      }
    }
  }

  Process {
    id: tracksProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.loadingTracks = false
        var d = root.parse(text)
        if (d && d.tracks) root.tracks = d.tracks
        else root.lastError = (d && d.error) ? d.error : "could not load tracks"
      }
    }
  }

  // Fetches a set of tracks only to hand their keys to the add-to-playlist
  // flow — used by the "+" on an album row, where the tracks are not loaded.
  Process {
    id: collectProc
    stdout: StdioCollector {
      onStreamFinished: {
        var d = root.parse(text)
        if (d && d.tracks && d.tracks.length > 0)
          root.requestAdd(d.tracks.map(function (t) { return t.key }))
        else root.showToast("Nothing to add there")
      }
    }
  }

  Process {
    id: playlistsProc
    command: [root.helper, "playlists", "list"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.loadingPlaylists = false
        var d = root.parse(text)
        if (d && d.playlists) root.playlists = d.playlists
      }
    }
  }

  Process {
    id: playlistWriteProc
    property string intent: ""
    stdout: StdioCollector {
      onStreamFinished: {
        root.addBusy = false
        var d = root.parse(text)
        if (!d || d.ok === false) {
          root.showToast((d && d.error) ? d.error : "Plex refused that")
          return
        }
        if (d.playlists) root.playlists = d.playlists
        var n = d.added || 0
        var name = ""
        if (d.created) name = d.created.title
        else if (d.key) {
          for (var i = 0; i < root.playlists.length; i++)
            if (String(root.playlists[i].key) === String(d.key)) name = root.playlists[i].title
        }
        root.showToast("Added " + n + (n === 1 ? " track" : " tracks")
                       + (name ? " to " + name : ""))
        root.addOpen = false
        root.pendingAdd = []
        // If we are looking at that playlist, show the new contents.
        if (root.view === "tracks" && root.selectedPlaylist
            && String(root.selectedPlaylist.key) === String(d.key || (d.created && d.created.key)))
          root.openPlaylist(root.selectedPlaylist)
      }
    }
  }

  function openArtist(a) {
    if (!a || !a.key) return
    root.selectedArtist = { key: String(a.key), title: a.title || "" }
    root.selectedAlbum = null
    root.selectedPlaylist = null
    root.albums = []
    root.view = "albums"
    root.loadingAlbums = true
    albumsProc.command = [root.helper, "albums", "--artist", String(a.key)]
    albumsProc.running = true
  }

  function openAlbum(al) {
    if (!al || !al.key) return
    root.selectedAlbum = al
    root.selectedPlaylist = null
    root.tracks = []
    root.view = "tracks"
    root.loadingTracks = true
    tracksProc.command = [root.helper, "tracks", "--album", String(al.key)]
    tracksProc.running = true
  }

  // Whether the now-playing line can take you somewhere.
  readonly property bool canRevealPlaying: playing && (trackAlbumKey !== "" || trackArtistKey !== "")

  // Open what is playing: its album, with its artist behind it so Back lands
  // on the artist's albums. Everything goes by the Plex keys the helper
  // reported for the playing track, never by searching for a name. With no
  // album key (an old queue) it falls back to the artist; with neither it
  // says so and stays where it is. Returns whether it navigated.
  function revealPlaying() {
    if (!root.playing) return false
    if (root.trackAlbumKey !== "") {
      if (root.trackArtistKey !== "") {
        root.selectedArtist = { key: root.trackArtistKey, title: root.trackArtist }
        root.albums = []
        root.loadingAlbums = true
        albumsProc.command = [root.helper, "albums", "--artist", root.trackArtistKey]
        albumsProc.running = true
      } else {
        root.selectedArtist = null
      }
      root.openAlbum({
        key: root.trackAlbumKey,
        title: root.trackAlbum,
        year: root.trackAlbumYear,
        artUrl: root.artPath !== "" ? "file://" + root.artPath : ""
      })
      return true
    }
    if (root.trackArtistKey !== "") {
      root.openArtist({ key: root.trackArtistKey, title: root.trackArtist })
      return true
    }
    root.showToast("Plex did not say which album this track is from")
    return false
  }

  function openPlaylist(p) {
    if (!p || !p.key) return
    root.selectedPlaylist = p
    root.selectedAlbum = null
    root.tracks = []
    root.view = "tracks"
    root.loadingTracks = true
    tracksProc.command = [root.helper, "tracks", "--playlist", String(p.key)]
    tracksProc.running = true
  }

  Process {
    id: stationsProc
    command: [root.helper, "stations"]
    stdout: StdioCollector {
      onStreamFinished: {
        var d = root.parse(text)
        if (d && d.decades) {
          root.stationDecades = d.decades
          root.stationStyles = d.styles || []
          root.stationMoods = d.moods || []
          root.stationsLoaded = true
        }
        decadesProc.running = true
      }
    }
  }
  Process {
    id: decadesProc
    command: [root.helper, "decades", "--size", "14"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.loadingStations = false
        var d = root.parse(text)
        if (d && d.rows) root.decadeRows = d.rows
      }
    }
  }

  function refreshStations(force) {
    if (root.loadingStations) return
    // Ten minutes is fresh enough; the radios themselves are built live.
    if (root.stationsLoaded && !force && (Date.now() - root.stationsAt) < 600000) return
    root.loadingStations = true
    root.stationsAt = Date.now()
    stationsProc.running = true
  }

  // kind: library | deepcuts | randomalbum | timetravel | decade | style | mood
  function playStation(kind, value) {
    var args = [root.helper, "station", String(kind)]
    if (kind === "decade") args.push("--decade", String(value))
    else if (kind === "style" || kind === "mood") args.push("--key", String(value))
    if (root.loop) args.push("--loop")
    root.stationPick = ""
    playProc.command = args
    playProc.running = true
  }

  function showTab(tab) {
    if (tab === "playlists") {
      root.view = "playlists"
      root.refreshPlaylists()
      return
    }
    if (tab === "songs") { root.view = "songs"; return }
    if (tab === "stations") { root.view = "stations"; root.stationPick = ""; root.refreshStations(false); return }
    root.browseAll = (tab === "all")
    root.view = "artists"
  }

  function back() {
    if (root.view === "tracks") {
      if (root.selectedPlaylist) { root.view = "playlists"; return }
      if (root.selectedArtist) { root.view = "albums"; return }
    }
    root.view = "artists"
  }

  function refreshPlaylists() {
    root.loadingPlaylists = true
    playlistsProc.running = true
  }

  function playAlbum(key, startAt) {
    if (!key) return
    var args = [root.helper, "play", "--album", String(key)]
    if (startAt) args.push("--start-at", String(startAt))
    else if (root.shuffle) args.push("--shuffle")
    if (root.loop) args.push("--loop")
    playProc.command = args
    playProc.running = true
  }

  function playPlaylist(key, startAt) {
    if (!key) return
    var args = [root.helper, "play", "--playlist", String(key)]
    if (startAt) args.push("--start-at", String(startAt))
    else if (root.shuffle) args.push("--shuffle")
    if (root.loop) args.push("--loop")
    playProc.command = args
    playProc.running = true
  }

  function playTracks(keys) {
    if (!keys || keys.length === 0) return
    var args = [root.helper, "play", "--tracks", keys.join(",")]
    if (root.loop) args.push("--loop")
    playProc.command = args
    playProc.running = true
  }

  function setLoop(on) {
    root.loop = !!on
    // Applies to the queue that is playing now as well as the next one.
    cmdProc.command = [root.helper, "cmd", "loop", "--value", root.loop ? "1" : "0"]
    cmdProc.running = true
  }

  function requestAdd(keys) {
    if (!keys || keys.length === 0) return
    root.pendingAdd = keys
    root.addOpen = true
    root.refreshPlaylists()
  }

  function requestAddAlbum(albumKey) {
    if (!albumKey) return
    collectProc.command = [root.helper, "tracks", "--album", String(albumKey)]
    collectProc.running = true
  }

  function addToPlaylist(playlistKey) {
    if (!playlistKey || root.pendingAdd.length === 0 || root.addBusy) return
    root.addBusy = true
    playlistWriteProc.command = [root.helper, "playlists", "add",
                                 "--key", String(playlistKey),
                                 "--tracks", root.pendingAdd.join(",")]
    playlistWriteProc.running = true
  }

  function createPlaylist(title) {
    var t = String(title || "").trim()
    if (!t || root.pendingAdd.length === 0 || root.addBusy) return
    root.addBusy = true
    playlistWriteProc.command = [root.helper, "playlists", "create",
                                 "--title", t, "--tracks", root.pendingAdd.join(",")]
    playlistWriteProc.running = true
  }

  // ---- settings -----------------------------------------------------------

  Process {
    id: serversProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.loadingServers = false
        root.settingsBusy = false
        var d = root.parse(text)
        if (d && d.servers) {
          root.servers = d.servers
          if (d.active !== undefined) root.server = d.active || ""
          if (d.added !== undefined)
            root.settingsNote = d.reachable
              ? "Using " + d.added + " (" + d.ms + " ms)"
              : d.added + " did not answer — kept in the list, not in use"
        } else if (d && d.error) {
          root.settingsNote = d.error
        }
        root.refreshStatus()
      }
    }
  }

  Process {
    id: serverWriteProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.settingsBusy = false
        var d = root.parse(text)
        if (d && d.added !== undefined) {
          root.settingsNote = d.reachable
            ? "Using " + d.added + " (" + d.ms + " ms)"
            : d.added + " did not answer — kept in the list, not in use"
          if (d.active !== undefined) root.server = d.active || ""
          if (d.section) root.section = String(d.section)
          // The first-run trap. The natural order is link the account, then
          // add the server — and the link poll's index attempt had no address
          // to use, so it died in resolve_base() and nothing ever tried again.
          // A reachable address now indexes itself.
          if (d.reachable && root.linked && root.artistCount === 0
              && !root.indexing) {
            root.settingsNote = "Indexing the library…"
            root.firstIndexTried = true
            Qt.callLater(function () { root.reindex() })
          }
        } else if (d && d.error) {
          root.settingsNote = d.error
        }
        root.refreshServers()
        root.refreshStatus()
      }
    }
  }

  Process {
    id: accountProc
    command: [root.helper, "account"]
    stdout: StdioCollector {
      onStreamFinished: {
        var d = root.parse(text)
        if (d) root.account = d
      }
    }
  }

  Process {
    id: sectionsProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.settingsBusy = false
        var d = root.parse(text)
        if (d && d.sections) root.sections = d.sections
        if (d && d.error) root.settingsNote = d.error
      }
    }
  }

  Process {
    id: forgetProc
    command: [root.helper, "link", "forget"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.settingsBusy = false
        root.linked = false
        root.server = ""
        root.artists = []
        root.letterIndex = ({})
        root.favourites = []
        root.servers = []
        root.sections = []
        root.account = ({})
        root.view = "artists"
        root.control("stop")
        root.refreshStatus()
      }
    }
  }

  function openSettings() {
    root.view = "settings"
    root.settingsNote = ""
    root.refreshServers()
    root.refreshAccount()
    root.refreshSections()
  }

  function refreshServers() {
    root.loadingServers = true
    serversProc.command = [root.helper, "server"]
    serversProc.running = true
  }

  // Adds (if new) and pins an address the user typed or picked.
  function useServer(uri) {
    if (!uri) return
    root.settingsBusy = true
    root.settingsNote = "Checking " + uri + "…"
    serverWriteProc.command = [root.helper, "server", "--use", String(uri)]
    serverWriteProc.running = true
  }

  function removeServer(uri) {
    if (!uri) return
    root.settingsBusy = true
    serverWriteProc.command = [root.helper, "server", "--remove", String(uri)]
    serverWriteProc.running = true
  }

  function refreshAccount() { accountProc.running = true }

  function refreshSections() {
    sectionsProc.command = [root.helper, "sections"]
    sectionsProc.running = true
  }

  function useSection(key) {
    if (!key) return
    root.settingsBusy = true
    sectionsProc.command = [root.helper, "sections", "--use", String(key)]
    sectionsProc.running = true
    // The old index is gone; build the new one straight away.
    Qt.callLater(function () { root.reindex() })
  }

  function unlink() {
    root.settingsBusy = true
    forgetProc.running = true
  }

  function showToast(message) {
    root.toast = message || ""
    toastTimer.restart()
  }

  Timer {
    id: toastTimer
    interval: 3200
    onTriggered: root.toast = ""
  }

  // ---- timers -------------------------------------------------------------

  // Poll the player. Fast while the panel is up so the vinyl and the progress
  // stay honest, slower in the background so the bar text is merely current.
  Timer {
    interval: root.spectrumWanted ? 500 : 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshNow()
  }

  Timer {
    id: linkPollTimer
    interval: 2000
    repeat: true
    onTriggered: linkPollProc.running = true
  }

  // ---- spectrum -----------------------------------------------------------

  onCavaWantedChanged: {
    if (cavaWanted) {
      cavaProc.command = ["cava", "-p", root.pluginDir + "share/cava.conf"]
      cavaProc.running = true
    } else {
      cavaProc.running = false
      root.levels = []
    }
  }

  Connections {
    target: cavaProc
    function onExited(exitCode, exitStatus) {
      root.levels = []
      // Most likely cava is not installed; say so rather than show a flat line.
      if (root.cavaWanted && exitCode !== 0)
        root.lastError = "cava not available — install it for the spectrum meters"
    }
  }

  // Deliberately no IpcHandler here. A plugin-declared handler does not get
  // registered in this two-entry-point plugin model — the shell's own base
  // panel type owns those targets. Bind keys to the helper instead:
  //
  //   .../plugins/io.github.mfilm77.plexmusic/bin/plexmusic cmd play-pause

  Component.onCompleted: {
    refreshStatus()
    refreshFavourites()
    // A scan may have been running when the shell restarted; find out before
    // the panel offers a Rescan that would start a second one.
    progressProc.running = true
  }

  Component.onDestruction: cavaProc.running = false
}
