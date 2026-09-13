import QtQuick
import Quickshell
import Quickshell.Io

// Always-loaded state for the plugin: what is playing, the starred artists,
// search results, and the spectrum frame the panel draws.
//
// None of the Plex or mpv work happens here. It all goes through `bin/plexmusic`,
// which speaks JSON on stdout, because holding an HTTP session and an mpv IPC
// socket open from QML would put the whole shell at the mercy of a slow server.
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

  // ---- account + server ---------------------------------------------------
  property bool linked: false
  property string server: ""
  property int artistCount: 0
  property string lastError: ""
  // The link flow, while it is running.
  property string linkCode: ""
  property bool linking: false

  // ---- library ------------------------------------------------------------
  property var favourites: []
  property var searchResults: []
  property string query: ""
  property bool searching: false

  // ---- playback -----------------------------------------------------------
  property bool playing: false
  property bool paused: false
  property string trackTitle: ""
  property string trackArtist: ""
  property string trackAlbum: ""
  property string artPath: ""
  property real position: 0
  property real duration: 0
  property int queuePos: 0
  property int queueCount: 0
  property bool shuffle: true

  // ---- spectrum -----------------------------------------------------------
  // One frame of cava's raw output: `bars` values, each 0-100. The panel turns
  // these into the meter band; nothing else reads them.
  property var levels: []
  readonly property int barCount: 64
  // cava is only worth running while something is looking at it.
  property bool spectrumWanted: false

  readonly property string label: {
    if (!playing) return "Plex Music"
    if (trackTitle && trackArtist) return trackTitle + " — " + trackArtist
    return trackTitle || trackAlbum || "Plex Music"
  }

  function parse(text) {
    try {
      return JSON.parse(text)
    } catch (e) {
      return null
    }
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
        root.artistCount = d.artistCount || 0
      }
    }
  }

  Process {
    id: favProc
    property string action: "list"
    command: [root.helper, "favourites", action]
    stdout: StdioCollector {
      onStreamFinished: {
        var d = root.parse(text)
        if (d && d.items) root.favourites = d.items
      }
    }
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      onStreamFinished: {
        var d = root.parse(text)
        root.searching = false
        root.searchResults = (d && d.results) ? d.results : []
      }
    }
  }

  Process {
    id: playProc
    stdout: StdioCollector {
      onStreamFinished: {
        var d = root.parse(text)
        if (d && d.ok === false) root.lastError = d.error || "could not play that"
        else root.lastError = ""
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
        root.playing = !!d.playing
        if (!d.playing) {
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
        root.position = d.position || 0
        root.duration = d.duration || 0
        root.queuePos = (d.playlistPos || 0) + 1
        root.queueCount = d.playlistCount || 0
      }
    }
  }

  Process {
    id: indexProc
    command: [root.helper, "index"]
    stdout: StdioCollector {
      onStreamFinished: {
        var d = root.parse(text)
        if (d && d.artistCount) root.artistCount = d.artistCount
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
          indexProc.running = true
        }
      }
    }
  }

  Process {
    id: cavaProc
    running: false
    // cava prints one frame per line: 64 values 0-100 separated by ';'. At 60
    // fps that is a line every 16 ms, so this parser must stay cheap — no
    // allocation beyond the one array the panel binds to.
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
  function refreshFavourites() { favProc.action = "list"; favProc.running = true }
  function reindex() { indexProc.running = true }

  function search(text) {
    root.query = text
    if (!text || text.trim() === "") {
      root.searchResults = []
      root.searching = false
      searchDebounce.stop()
      return
    }
    root.searching = true
    searchDebounce.restart()
  }

  function playArtist(key) {
    if (!key) return
    var args = [root.helper, "play", "--key", String(key)]
    if (root.shuffle) args.push("--shuffle")
    playProc.command = args
    playProc.running = true
  }

  function control(action) {
    cmdProc.command = [root.helper, "cmd", action]
    cmdProc.running = true
  }

  function setVolume(value) {
    cmdProc.command = [root.helper, "cmd", "volume", "--value", String(value)]
    cmdProc.running = true
  }

  function isFavourite(key) {
    var k = String(key)
    for (var i = 0; i < favourites.length; i++)
      if (String(favourites[i].key) === k) return true
    return false
  }

  function toggleFavourite(key, title) {
    var fav = isFavourite(key)
    var args = [root.helper, "favourites", fav ? "remove" : "add",
                "--key", String(key)]
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

  // ---- timers -------------------------------------------------------------

  Timer {
    id: searchDebounce
    interval: 160
    onTriggered: {
      searchProc.command = [root.helper, "search", root.query, "--limit", "80"]
      searchProc.running = true
    }
  }

  // Poll the player. Fast while the panel is up so the vinyl and the progress
  // stay honest, slow in the background so the bar text is merely current.
  Timer {
    interval: root.spectrumWanted ? 500 : 3000
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
  //
  // cava does the FFT and prints one line per frame: `bars` values 0-100
  // separated by ';'. Running it only while the panel is open keeps an idle
  // bar from costing anything.
  onSpectrumWantedChanged: {
    if (spectrumWanted) {
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
      // Most likely cava is not installed; say so once rather than silently
      // showing a flat line forever.
      if (root.spectrumWanted && exitCode !== 0)
        root.lastError = "cava not available — install it for the spectrum meters"
    }
  }

  // Deliberately no IpcHandler here. A plugin-declared handler does not get
  // registered in this two-entry-point plugin model — the shell's own base
  // panel type owns those targets. Bind keys to the helper instead, which needs
  // no shell at all:
  //
  //   .../plugins/io.github.mfilm77.plexmusic/bin/plexmusic cmd play-pause
  //   .../plugins/io.github.mfilm77.plexmusic/bin/plexmusic cmd next

  Component.onCompleted: {
    refreshStatus()
    refreshFavourites()
  }

  // The parser lives inside the cava Process so it is torn down with it.
  Component.onDestruction: cavaProc.running = false
}
