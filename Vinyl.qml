import QtQuick
import QtQuick.Effects
import qs.Commons

// A record on a platter: black disc, cut grooves, the album cover as the label.
//
// It turns at 33 1/3 rpm — 1.8 seconds a revolution — because a record that
// spins at some arbitrary speed looks wrong to anyone who owns one. Pausing
// stops it where it is rather than snapping back to zero.
Item {
  id: root

  property bool spinning: false
  property string art: ""
  property real labelRatio: 0.29      // label diameter as a share of the disc

  // Never negative: the panel's arithmetic can go below zero mid-layout and
  // every radius below depends on this.
  readonly property real size: Math.max(0, Math.min(width, height))
  readonly property real labelSize: size * labelRatio

  // ---- neon ----------------------------------------------------------------
  //
  // A ring of light around the record, pink on one side and blue on the
  // other, that breathes with the volume: full at 100, a glimmer at 0, off
  // when nothing is on. Drawn behind the platter as widening, fading strokes.
  property real volume: 100
  Canvas {
    id: neon
    anchors.centerIn: platter
    // Wide enough that the glow has died away long before the edge of the
    // canvas — a glow cut by its own box reads as a square.
    width: platter.width * 2.2
    height: width
    z: -1
    antialiasing: true
    smooth: true
    renderStrategy: Canvas.Cooperative
    opacity: root.engaged ? (0.12 + 0.88 * Math.max(0, Math.min(100, root.volume)) / 100) : 0
    Behavior on opacity { NumberAnimation { duration: 260 } }
    onPaint: {
      if (!(width > 0)) return
      var ctx = getContext("2d"); ctx.reset()
      var c = width / 2, r = platter.width / 2
      var a = Color.accent, u = Color.urgent
      function rgba(col, al) { return "rgba(" + Math.round(col.r*255) + "," + Math.round(col.g*255) + "," + Math.round(col.b*255) + "," + al + ")" }
      // Many thin full rings, alpha falling off smoothly with radius (no
      // steps), each carrying a conical gradient with 48 stops sampled from a
      // cosine blend of the two tones (no seams). Two pink/blue cycles around
      // the ring, phased so pink sits top-right and bottom-left.
      function blend(w) {
        return [u.r * w + a.r * (1 - w), u.g * w + a.g * (1 - w), u.b * w + a.b * (1 - w)]
      }
      var rings = 44
      for (var i = 0; i < rings; i++) {
        var f = i / (rings - 1)
        var rr = r * (1.006 + 0.58 * Math.pow(f, 1.4))  // out to ~1.6 r
        var lw = 2 + 14 * f                              // widths overlap for a solid falloff
        var al = 0.50 * Math.pow(1 - f, 3.0)             // and reach zero at the last ring
        var g = ctx.createConicalGradient(c, c, 0)
        for (var q = 0; q <= 48; q++) {
          var ang = q / 48 * Math.PI * 2
          var w = 0.5 + 0.5 * Math.cos(2 * ang - 0.9)
          var col = blend(w)
          g.addColorStop(q / 48, "rgba(" + Math.round(col[0]*255) + "," + Math.round(col[1]*255) + "," + Math.round(col[2]*255) + "," + al + ")")
        }
        ctx.strokeStyle = g; ctx.lineWidth = lw
        ctx.beginPath(); ctx.arc(c, c, rr, 0, Math.PI * 2); ctx.stroke()
      }
    }
  }

  // ---- the disc ------------------------------------------------------------

  Item {
    id: platter
    // The platter takes the lower-left 78% of the item. The strip above and
    // to the right is where the arm's bearing sits — back-right of the
    // platter, as on a deck seen from above.
    width: root.size * 0.80
    height: width
    x: 0
    y: root.size * 0.10

    // Everything that must turn with the record lives in here.
    Item {
      id: turning
      anchors.fill: parent

      // The vinyl itself. Not flat black: a record picks up a sheen from the
      // room, and without it the disc reads as a hole in the panel.
      Rectangle {
        anchors.fill: parent
        radius: width / 2
        gradient: Gradient {
          GradientStop { position: 0.0; color: "#22242a" }
          GradientStop { position: 0.45; color: "#0e0f13" }
          GradientStop { position: 1.0; color: "#05060a" }
        }
      }

      // The grooves. Drawn once into a canvas — a Repeater of 90 circles is the
      // obvious way and it costs 90 nodes that never change.
      Canvas {
        id: grooves
        anchors.fill: parent
        antialiasing: true
        renderStrategy: Canvas.Cooperative
        onPaint: {
          // Canvas paints once before the panel has been laid out, when the
          // width can still be 0 or briefly negative. A negative radius is a
          // hard error in Qt's 2D context, so bail out rather than draw.
          if (!(width > 0) || !(height > 0)) return
          var c = width / 2
          var outer = Math.max(0, c * 0.985)
          var inner = Math.max(0, c * (root.labelRatio / 2) * 1.08)
          // Math.max(0, NaN) is NaN, and a NaN radius is the same hard error.
          if (!isFinite(outer) || !isFinite(inner) || inner > outer) return
          var ctx = getContext("2d")
          ctx.reset()
          // Groove pitch is not uniform on a real record; a slight variation
          // stops the rings reading as a moiré pattern on a screen.
          var rings = 78
          for (var i = 0; i < rings; i++) {
            var t = i / (rings - 1)
            var r = outer - (outer - inner) * t
            ctx.beginPath()
            ctx.arc(c, c, r, 0, Math.PI * 2)
            ctx.lineWidth = (i % 9 === 0) ? 1.4 : 0.7
            ctx.strokeStyle = (i % 9 === 0)
              ? "rgba(255,255,255,0.075)" : "rgba(255,255,255,0.035)"
            ctx.stroke()
          }
          // The run-out band nearest the label reads as smooth vinyl.
          ctx.beginPath()
          ctx.arc(c, c, inner * 0.94, 0, Math.PI * 2)
          ctx.lineWidth = 2
          ctx.strokeStyle = "rgba(255,255,255,0.05)"
          ctx.stroke()
        }
      }

      // The label: the real album cover, cropped to a circle. This is the whole
      // point of the thing, so it gets the accent ring rather than a grey edge.
      Item {
        id: label
        width: root.labelSize
        height: root.labelSize
        anchors.centerIn: parent
        // The whole label — cover, mask and ring — is rendered into one
        // multisampled layer, so its edge stays smooth as the record turns.
        layer.enabled: true
        layer.smooth: true
        layer.samples: 4
        layer.textureSize: Qt.size(Math.max(2, Math.round(width * 2)),
                                   Math.max(2, Math.round(height * 2)))

        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: Qt.darker(Color.popups.background, 1.4)
        }

        Image {
          id: cover
          anchors.fill: parent
          source: root.art ? "file://" + root.art : ""
          fillMode: Image.PreserveAspectCrop
          cache: true
          asynchronous: true
          smooth: true
          mipmap: true
          visible: false
          sourceSize.width: 500
          sourceSize.height: 500
        }

        MultiEffect {
          anchors.fill: parent
          source: cover
          maskEnabled: true
          maskSource: labelMask
          // Soften the mask edge a touch either side of the threshold; with a
          // hard threshold the circle is cut on whole pixels and looks jagged.
          maskThresholdMin: 0.4
          maskSpreadAtMin: 0.6
          visible: cover.status === Image.Ready
        }

        // The circular mask, rendered at twice the label's size with
        // antialiasing so its edge is smooth once scaled onto the cover.
        Item {
          id: labelMask
          width: root.labelSize
          height: root.labelSize
          layer.enabled: true
          layer.smooth: true
          layer.textureSize: Qt.size(Math.max(2, Math.round(width * 2)),
                                     Math.max(2, Math.round(height * 2)))
          visible: false
          Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "black"
            antialiasing: true
          }
        }

        // No cover in Plex: show the accent monogram rather than a grey hole.
        Text {
          anchors.centerIn: parent
          visible: cover.status !== Image.Ready
          text: "󰃽"
          font.pixelSize: parent.height * 0.4
          color: Qt.rgba(Color.foreground.r, Color.foreground.g,
                         Color.foreground.b, 0.35)
        }

        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: "transparent"
          border.width: 1.5
          border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55)
          antialiasing: true
        }
      }

      // The spindle hole. Small, but its absence is what makes a drawn record
      // look like a dark coaster.
      Rectangle {
        anchors.centerIn: parent
        width: root.size * 0.022
        height: width
        radius: width / 2
        color: Qt.darker(Color.popups.background, 2.2)
        border.width: 1
        border.color: Qt.rgba(0, 0, 0, 0.6)
      }

      RotationAnimator {
        target: turning
        from: 0
        to: 360
        duration: 1800          // 33 1/3 rpm
        loops: Animation.Infinite
        running: root.spinning
      }
    }

    // The reflection vinyl shows under a light: cool, soft streaks radiating
    // from the label, fixed in place while the grooves turn beneath them —
    // which is what sells the rotation. Painted once, very low alpha.
    Canvas {
      id: gloss
      anchors.fill: parent
      antialiasing: true
      renderStrategy: Canvas.Cooperative
      onPaint: {
        if (!(width > 0)) return
        var c = width / 2
        var outer = c * 0.985
        var inner = Math.max(0, c * (root.labelRatio / 2) * 1.06)
        if (!isFinite(outer) || !isFinite(inner) || inner >= outer) return
        var ctx = getContext("2d")
        ctx.reset()
        // Clip to the grooved ring.
        ctx.beginPath()
        ctx.arc(c, c, outer, 0, Math.PI * 2)
        ctx.arc(c, c, inner, 0, Math.PI * 2, true)
        ctx.clip()
        // Uneven light wedges around the disc, brighter on the lit side.
        var cg = ctx.createConicalGradient(c, c, -0.6)
        var stops = [
          [0.00, 0.00], [0.06, 0.30], [0.10, 0.04], [0.17, 0.17], [0.24, 0.00],
          [0.31, 0.10], [0.36, 0.00], [0.47, 0.20], [0.53, 0.04], [0.58, 0.26],
          [0.64, 0.00], [0.74, 0.12], [0.80, 0.00], [0.88, 0.19], [0.94, 0.02],
          [1.00, 0.00]
        ]
        for (var i = 0; i < stops.length; i++)
          cg.addColorStop(stops[i][0], "rgba(150,200,255," + stops[i][1] + ")")
        ctx.fillStyle = cg
        ctx.fillRect(0, 0, width, height)
        // Radial fade: strongest a third of the way out, gone at the rim.
        var rg = ctx.createRadialGradient(c, c, inner, c, c, outer)
        rg.addColorStop(0.0, "rgba(5,8,14,0.10)")
        rg.addColorStop(0.35, "rgba(5,8,14,0.0)")
        rg.addColorStop(0.75, "rgba(5,8,14,0.25)")
        rg.addColorStop(1.0, "rgba(5,8,14,0.55)")
        ctx.fillStyle = rg
        ctx.fillRect(0, 0, width, height)
        // A faint bright ring at the run-out, as the photo has.
        ctx.beginPath()
        ctx.arc(c, c, inner * 1.05, 0, Math.PI * 2)
        ctx.lineWidth = Math.max(1, c * 0.02)
        ctx.strokeStyle = "rgba(150,200,255,0.12)"
        ctx.stroke()
      }
    }

    // The linear sheen, kept but quieter now the streaks carry the light.
    Rectangle {
      anchors.fill: parent
      radius: width / 2
      opacity: 0.3
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: "transparent" }
        GradientStop { position: 0.30; color: Qt.rgba(1, 1, 1, 0.045) }
        GradientStop { position: 0.44; color: "transparent" }
        GradientStop { position: 0.62; color: Qt.rgba(1, 1, 1, 0.02) }
        GradientStop { position: 1.0; color: "transparent" }
      }
    }

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: "transparent"
      border.width: 1
      border.color: Qt.rgba(Color.foreground.r, Color.foreground.g,
                            Color.foreground.b, 0.12)
    }
  }

  // ---- the tonearm ---------------------------------------------------------
  //
  // A pivoting arm as a deck has it: bearing housing at the top-right of the
  // platter, a counterweight behind the pivot, a tube out to an angled
  // headshell carrying the cartridge and stylus. An arm rest sits to the right
  // of the platter and the arm parks on it when nothing is on.
  //
  // `progress` is 0-1 through the whole side — first track at the outermost
  // groove, last track at the label — and `engaged` is whether a record is on.
  property real progress: 0
  property bool engaged: false

  // Pivot and length in platter units, solved for a real deck's path: the
  // pivot is behind and to the right of the platter, the arm reaches forward
  // and left, the stylus lands at the record's right side (about three
  // o'clock, r = 0.47) for the first track and arcs in to the label edge
  // (r = 0.21) for the last. In Qt's clockwise rotation about the pivot that
  // is -96.3 degrees at the outer groove and -68.9 at the label. The rest is
  // four degrees further out, just off the edge, so cueing is a lift and a
  // short move inward — never a sweep across the label.
  // From the reference photos: a long arm from a bearing at the back-right,
  // reaching almost straight forward; the needle drops at the record's
  // lower-right (r = 0.47 at t = 70.6 deg) and arcs in to the label (r = 0.21
  // at 52 deg); the rest is just off the lower-right edge at 80 deg, the arm
  // parked nearly vertical along the platter's right side.
  // Measured off a top-down photograph of a real deck (platter width = 1):
  // bearing at (1.065, 0.15), needle 0.71 from it. Playing, the needle drops
  // at the record's lower-right (r = 0.47 at 72 deg) and arcs in to the label
  // (r = 0.21 at 48.5 deg). At rest the arm hangs straight down at 90 deg,
  // its tube at x = 1.065 — wholly outside the record, with a visible gap.
  // Measured off top-down photographs of real decks (platter width = 1):
  // bearing at (1.115, 0.12), needle 0.74 from it. Playing, the needle drops
  // at the record's lower-right (r = 0.47 at 70.5 deg) and arcs in to the
  // label (r = 0.21 at 48 deg). At rest the arm hangs almost straight down at
  // 85 deg with its tube wholly outside the record — a clear margin, as in
  // every photo.
  readonly property real pivotX: platter.x + platter.width * 1.13
  readonly property real pivotY: platter.y + platter.height * 0.12
  readonly property real armLen: platter.width * 0.74       // pivot to stylus
  readonly property real cwLen: platter.width * 0.08        // pivot to counterweight end
  readonly property real angleOn: -(68.3 - Math.max(0, Math.min(1, root.progress)) * 20.8)
  // Parked alongside the platter, never over it.
  readonly property real angleRest: -88

  readonly property color metal: Qt.rgba(
    Color.foreground.r * 0.85 + 0.10, Color.foreground.g * 0.85 + 0.10,
    Color.foreground.b * 0.85 + 0.10, 1)
  readonly property color metalDark: Qt.darker(metal, 1.9)
  readonly property color housing: Qt.rgba(metal.r * 0.55, metal.g * 0.55, metal.b * 0.58, 1)

  // The arm rest: a small post with a clip that holds the tube about halfway
  // along its length when parked — the headshell hangs on past it.
  Item {
    x: root.pivotX - root.armLen * 0.55 * Math.cos(88 * Math.PI / 180) - width / 2
    y: root.pivotY + root.armLen * 0.55 * Math.sin(88 * Math.PI / 180) - height * 0.5
    width: root.size * 0.048
    height: root.size * 0.05
    z: 1
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      width: parent.width * 0.42
      height: parent.height
      radius: 2
      color: root.housing
      border.width: 1
      border.color: Qt.rgba(0, 0, 0, 0.5)
    }
    Rectangle {
      anchors.top: parent.top
      width: parent.width
      height: parent.height * 0.36
      radius: 3
      color: root.housing
      border.width: 1
      border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.25)
    }
  }

  // The bearing: a polished round base the arm turns in. Static.
  Item {
    id: bearing
    x: root.pivotX - width / 2
    y: root.pivotY - height / 2
    width: platter.width * 0.15
    height: width
    z: 3
    Canvas {
      anchors.fill: parent
      antialiasing: true
      smooth: true
      renderStrategy: Canvas.Cooperative
      onPaint: {
        if (!(width > 0)) return
        var ctx = getContext("2d"); ctx.reset()
        var c = width / 2, r = c * 0.96
        var m = root.metal
        function rgba(col, a) { return "rgba(" + Math.round(col.r*255) + "," + Math.round(col.g*255) + "," + Math.round(col.b*255) + "," + a + ")" }
        // Shadow on the plinth.
        var sh = ctx.createRadialGradient(c, c + r * 0.15, r * 0.6, c, c + r * 0.15, r * 1.25)
        sh.addColorStop(0, "rgba(0,0,0,0.45)"); sh.addColorStop(1, "rgba(0,0,0,0)")
        ctx.fillStyle = sh; ctx.beginPath(); ctx.arc(c, c + r * 0.15, r * 1.25, 0, Math.PI * 2); ctx.fill()
        // Base disc, brushed: light top-left to dark bottom-right.
        var g = ctx.createLinearGradient(c - r, c - r, c + r, c + r)
        g.addColorStop(0, rgba(Qt.lighter(m, 1.35), 1)); g.addColorStop(0.5, rgba(m, 1)); g.addColorStop(1, rgba(Qt.darker(m, 2.2), 1))
        ctx.fillStyle = g; ctx.beginPath(); ctx.arc(c, c, r, 0, Math.PI * 2); ctx.fill()
        ctx.lineWidth = 1; ctx.strokeStyle = "rgba(0,0,0,0.55)"; ctx.stroke()
        // Raised boss.
        var g2 = ctx.createLinearGradient(c, c - r * 0.5, c, c + r * 0.5)
        g2.addColorStop(0, rgba(Qt.lighter(m, 1.5), 1)); g2.addColorStop(1, rgba(Qt.darker(m, 1.9), 1))
        ctx.fillStyle = g2; ctx.beginPath(); ctx.arc(c, c, r * 0.5, 0, Math.PI * 2); ctx.fill()
        ctx.strokeStyle = "rgba(0,0,0,0.5)"; ctx.stroke()
        // Pivot pin.
        ctx.fillStyle = rgba(Qt.darker(m, 3), 1); ctx.beginPath(); ctx.arc(c, c, r * 0.12, 0, Math.PI * 2); ctx.fill()
      }
    }
  }

  // The arm itself, painted once as a single illustration — tube, headshell,
  // cartridge, stylus, counterweight — then rotated as one smooth texture
  // about the pivot. Painting it beats assembling it from rotated rectangles,
  // whose edges step and whose joins break.
  Item {
    id: arm
    // Local frame: the pivot is at (pivotLocalX, height/2); the tube runs
    // toward x = 0 where the headshell sits; the counterweight is to the right.
    // Generous room past the nose and above/below the line: the headshell is
    // rotated and must never touch the edge of its own painting box.
    readonly property real pad: root.size * 0.16
    readonly property real pivotLocalX: pad + root.armLen
    width: pivotLocalX + root.cwLen + root.size * 0.06
    height: root.size * 0.34
    x: root.pivotX - pivotLocalX
    y: root.pivotY - height / 2
    z: 2
    readonly property real tubeH: Math.max(3, platter.width * 0.028)
    readonly property real cy: height / 2
    readonly property real noseOff: -tubeH * 1.1     // lateral offset of the nose
    readonly property real angle: root.engaged ? root.angleOn : root.angleRest

    transform: Rotation {
      origin.x: arm.pivotLocalX
      origin.y: arm.cy
      angle: arm.angle
      Behavior on angle { NumberAnimation { duration: 1100; easing.type: Easing.InOutCubic } }
    }

    Canvas {
      id: armPaint
      anchors.fill: parent
      antialiasing: true
      smooth: true
      renderStrategy: Canvas.Cooperative
      onPaint: {
        if (!(width > 0) || !(height > 0)) return
        var ctx = getContext("2d"); ctx.reset()
        var m = root.metal, md = root.metalDark, acc = Color.accent
        function rgba(col, a) { return "rgba(" + Math.round(col.r*255) + "," + Math.round(col.g*255) + "," + Math.round(col.b*255) + "," + a + ")" }
        var px = arm.pivotLocalX, cy = arm.cy, T = arm.tubeH, L = root.armLen
        var nose = arm.pad + root.size * 0.035          // where the tube meets the headshell
        var off = arm.noseOff

        // ---- the tube path: straight out of the bearing, then a long S.
        function tubePath(dy) {
          ctx.beginPath()
          ctx.moveTo(px + root.size * 0.015, cy + dy)
          ctx.lineTo(px - L * 0.30, cy + dy)
          // One sweep: bows away from the spindle side, then comes back to
          // land on the nose heading the way the headshell points.
          ctx.bezierCurveTo(px - L * 0.72, cy + dy,  nose + L * 0.30, cy - off * 1.6 + dy,  nose, cy + off + dy)
        }
        ctx.lineCap = "round"; ctx.lineJoin = "round"
        // shadow
        tubePath(3); ctx.lineWidth = T * 1.1; ctx.strokeStyle = "rgba(0,0,0,0.35)"; ctx.stroke()
        // body: dark, then mid, then a highlight ridge along the top
        tubePath(0); ctx.lineWidth = T; ctx.strokeStyle = rgba(md, 1); ctx.stroke()
        tubePath(-T * 0.10); ctx.lineWidth = T * 0.62; ctx.strokeStyle = rgba(m, 1); ctx.stroke()
        tubePath(-T * 0.26); ctx.lineWidth = T * 0.22; ctx.strokeStyle = rgba(Qt.lighter(m, 1.45), 0.95); ctx.stroke()

        // ---- counterweight: a short fat cylinder behind the pivot.
        var cwX = px + root.size * 0.028, cwW = root.cwLen - root.size * 0.02, cwH = T * 2.6
        var cg = ctx.createLinearGradient(0, cy - cwH / 2, 0, cy + cwH / 2)
        cg.addColorStop(0, rgba(Qt.lighter(m, 1.3), 1)); cg.addColorStop(0.45, rgba(m, 1)); cg.addColorStop(1, rgba(Qt.darker(m, 2.4), 1))
        ctx.fillStyle = cg
        ctx.beginPath(); ctx.roundedRect(cwX, cy - cwH / 2, cwW, cwH, 2.5, 2.5); ctx.fill()
        ctx.lineWidth = 1; ctx.strokeStyle = "rgba(0,0,0,0.55)"; ctx.stroke()
        ctx.strokeStyle = "rgba(0,0,0,0.30)"
        for (var k = 1; k <= 4; k++) { var gx = cwX + cwW * k / 5; ctx.beginPath(); ctx.moveTo(gx, cy - cwH * 0.32); ctx.lineTo(gx, cy + cwH * 0.32); ctx.stroke() }

        // ---- headshell, modelled on a classic slim plate: a collar where it
        // meets the tube, a long flat shell with slots, a thin finger lift,
        // a small cartridge under the front and a tiny stylus. Every corner
        // rounded; nothing here should read as a block.
        ctx.save()
        ctx.translate(nose, cy + off)
        ctx.rotate(22 * Math.PI / 180)
        var hsL = root.size * 0.155, hsH = T * 1.55
        function metalGrad(y0, y1) {
          var gg = ctx.createLinearGradient(0, y0, 0, y1)
          gg.addColorStop(0, rgba(Qt.lighter(m, 1.35), 1)); gg.addColorStop(0.5, rgba(m, 1)); gg.addColorStop(1, rgba(Qt.darker(m, 2.0), 1))
          return gg
        }
        // collar
        ctx.fillStyle = metalGrad(-T * 0.9, T * 0.9)
        ctx.beginPath(); ctx.roundedRect(-hsL * 0.10, -T * 0.9, hsL * 0.14, T * 1.8, T * 0.35, T * 0.35); ctx.fill()
        ctx.lineWidth = 1; ctx.strokeStyle = "rgba(0,0,0,0.45)"; ctx.stroke()
        // plate shadow on the record
        ctx.fillStyle = "rgba(0,0,0,0.30)"
        ctx.beginPath(); ctx.roundedRect(-hsL, -hsH / 2 + 3, hsL * 0.94, hsH, hsH * 0.3, hsH * 0.3); ctx.fill()
        // plate
        ctx.fillStyle = metalGrad(-hsH / 2, hsH / 2)
        ctx.beginPath(); ctx.roundedRect(-hsL, -hsH / 2, hsL * 0.94, hsH, hsH * 0.3, hsH * 0.3); ctx.fill()
        ctx.strokeStyle = "rgba(0,0,0,0.5)"; ctx.stroke()
        // slots in the plate
        ctx.fillStyle = "rgba(0,0,0,0.35)"
        for (var q = 0; q < 3; q++) {
          ctx.beginPath(); ctx.roundedRect(-hsL * (0.30 + q * 0.18), -hsH * 0.14, hsL * 0.10, hsH * 0.28, 1, 1); ctx.fill()
        }
        // finger lift: a slim bar off the plate's back edge
        ctx.strokeStyle = rgba(Qt.lighter(m, 1.15), 1); ctx.lineWidth = Math.max(1.5, T * 0.38); ctx.lineCap = "round"
        ctx.beginPath(); ctx.moveTo(-hsL * 0.40, -hsH * 0.5); ctx.lineTo(-hsL * 0.62, -hsH * 1.15); ctx.stroke()
        // cartridge under the front: small, dark, with a thin accent line
        ctx.fillStyle = rgba(Qt.darker(m, 2.6), 1)
        ctx.beginPath(); ctx.roundedRect(-hsL * 0.96, hsH * 0.30, hsL * 0.30, hsH * 0.55, 1.5, 1.5); ctx.fill()
        ctx.strokeStyle = rgba(acc, 0.9); ctx.lineWidth = 1
        ctx.beginPath(); ctx.moveTo(-hsL * 0.93, hsH * 0.58); ctx.lineTo(-hsL * 0.69, hsH * 0.58); ctx.stroke()
        // stylus
        ctx.strokeStyle = rgba(Color.foreground, 0.95); ctx.lineWidth = Math.max(1, T * 0.2)
        ctx.beginPath(); ctx.moveTo(-hsL * 0.84, hsH * 0.85); ctx.lineTo(-hsL * 0.88, hsH * 1.25); ctx.stroke()
        ctx.restore()
      }
      Connections { target: root; function onSizeChanged() { armPaint.requestPaint() } }
    }
  }
}
