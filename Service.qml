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
  property string lastError: ""
  property string linkCode: ""
  property bool linking: false
  property bool indexing: false

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

  function parse(text) {
    try { return JSON.parse(text) } catch (e) { return null }
  }

  // Lower-case, accents stripped, matching the helper's fold(). Used only on
  // the typed query; the index arrives pre-folded.
  function fold(s) {
    s = String(s || "").toLowerCase()
    try { s = s.normalize("NFD").replace(/[\u0300-\u036f]/g, "") } catch (e) {}
    return s
  }

  // ---- the index ----------------------------------------------------------

  FileView {
    id: indexFile
    path: root.indexPath
    watchChanges: true
    onLoaded: root.applyIndex()
    onFileChanged: reload()
  }

  FileView {
    id: trackIndexFile
    path: root.trackIndexPath
    watchChanges: true
    onLoaded: root.applyTrackIndex()
    onFileChanged: reload()
  }

  function applyTrackIndex() {
    var d = root.parse(trackIndexFile.text())
    var list = (d && d.tracks) ? d.tracks : []
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
    var d = root.parse(indexFile.text())
    var list = (d && d.artists) ? d.artists : []
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
      }
    }
  }

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
        root.indexing = false
        var d = root.parse(text)
        if (d && d.ok === false) root.lastError = d.error || "could not index"
        // The FileView watches the index file and reloads it on its own.
        root.refreshStatus()
      }
    }
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
  function reindex() {
    if (root.indexing) return
    root.indexing = true
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

  function showTab(tab) {
    if (tab === "playlists") {
      root.view = "playlists"
      root.refreshPlaylists()
      return
    }
    if (tab === "songs") { root.view = "songs"; return }
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
  }

  Component.onDestruction: cavaProc.running = false
}
