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
  property real labelRatio: 0.36      // label diameter as a share of the disc

  // Never negative: the panel's arithmetic can go below zero mid-layout and
  // every radius below depends on this.
  readonly property real size: Math.max(0, Math.min(width, height))
  readonly property real labelSize: size * labelRatio

  // ---- the disc ------------------------------------------------------------

  Item {
    id: platter
    // The platter takes the left 84% of the item; the arm's bearing sits in
    // the strip to its right, as it does on a deck.
    width: root.size * 0.84
    height: width
    x: 0
    anchors.verticalCenter: parent.verticalCenter

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

    // The sheen stays put while the record turns underneath it, which is what
    // sells the rotation.
    Rectangle {
      anchors.fill: parent
      radius: width / 2
      opacity: 0.5
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

  // Pivot and length, in platter units, solved so the stylus arc crosses the
  // outermost groove in the upper right of the record and reaches the label
  // edge 28 degrees later — the diagonal sweep of a real arm seen from above.
  // At the outer groove the arm points up-left (+25.8 deg in Qt's clockwise
  // rotation); at the label it lies almost flat (-2.3 deg).
  readonly property real pivotX: platter.x + platter.width * 1.16
  readonly property real pivotY: platter.y + platter.height * 0.30
  readonly property real armLen: platter.width * 0.55       // pivot to stylus
  readonly property real cwLen: platter.width * 0.12        // pivot to counterweight end
  readonly property real angleOn: 25.8 - Math.max(0, Math.min(1, root.progress)) * 28.1
  readonly property real angleRest: -80                     // parked on the rest, off the disc

  readonly property color metal: Qt.rgba(
    Color.foreground.r * 0.85 + 0.10, Color.foreground.g * 0.85 + 0.10,
    Color.foreground.b * 0.85 + 0.10, 1)
  readonly property color metalDark: Qt.darker(metal, 1.9)
  readonly property color housing: Qt.rgba(metal.r * 0.55, metal.g * 0.55, metal.b * 0.58, 1)

  // The arm rest: a small post with a clip, where the headshell parks.
  Item {
    x: root.pivotX - root.armLen * Math.cos(80 * Math.PI / 180) - width / 2
    y: root.pivotY + root.armLen * Math.sin(80 * Math.PI / 180) - height * 0.55
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

  // The bearing housing does not turn; the arm turns inside it.
  Rectangle {
    id: bearing
    x: root.pivotX - width / 2
    y: root.pivotY - height / 2
    width: platter.width * 0.12
    height: width
    radius: width / 2
    z: 3
    antialiasing: true
    gradient: Gradient {
      GradientStop { position: 0.0; color: Qt.lighter(root.housing, 1.25) }
      GradientStop { position: 1.0; color: Qt.darker(root.housing, 1.5) }
    }
    border.width: 1
    border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.3)

    Rectangle {
      anchors.centerIn: parent
      width: parent.width * 0.42
      height: width
      radius: width / 2
      color: Qt.darker(root.housing, 2.2)
      border.width: 1
      border.color: Qt.rgba(0, 0, 0, 0.6)
      antialiasing: true
    }
  }

  Item {
    id: arm
    // Spans stylus (x = 0) to the back of the counterweight (x = width); the
    // pivot is inside it, cwLen from the right end.
    width: root.armLen + root.cwLen
    height: root.size * 0.09
    x: root.pivotX - root.armLen
    y: root.pivotY - height / 2
    z: 2
    readonly property real pivotLocalX: root.armLen
    readonly property real tubeH: Math.max(2.5, root.size * 0.026)

    transform: Rotation {
      origin.x: arm.pivotLocalX
      origin.y: arm.height / 2
      angle: root.engaged ? root.angleOn : root.angleRest
      Behavior on angle {
        NumberAnimation { duration: 1100; easing.type: Easing.InOutCubic }
      }
    }

    // Shadow under the tube, so the arm floats above the record.
    Rectangle {
      x: root.size * 0.09
      y: arm.height / 2 - arm.tubeH / 2 + 3
      width: arm.pivotLocalX - x
      height: arm.tubeH
      radius: height / 2
      color: Qt.rgba(0, 0, 0, 0.35)
    }

    // The tube: a cylinder, lit from above.
    Rectangle {
      id: tube
      x: root.size * 0.08
      y: arm.height / 2 - arm.tubeH / 2
      width: arm.pivotLocalX - x + root.size * 0.02
      height: arm.tubeH
      radius: height / 2
      antialiasing: true
      gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.lighter(root.metal, 1.25) }
        GradientStop { position: 0.45; color: root.metal }
        GradientStop { position: 1.0; color: root.metalDark }
      }
    }

    // Counterweight: a fat knurled cylinder behind the pivot.
    Rectangle {
      x: arm.pivotLocalX + root.size * 0.035
      y: arm.height / 2 - height / 2
      width: root.cwLen - root.size * 0.035
      height: arm.tubeH * 2.6
      radius: 3
      antialiasing: true
      gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.lighter(root.housing, 1.4) }
        GradientStop { position: 0.5; color: root.housing }
        GradientStop { position: 1.0; color: Qt.darker(root.housing, 1.8) }
      }
      border.width: 1
      border.color: Qt.rgba(0, 0, 0, 0.55)
      // Knurling.
      Row {
        anchors.centerIn: parent
        spacing: 2
        Repeater {
          model: 4
          Rectangle { width: 1; height: parent.parent.height * 0.6; color: Qt.rgba(0, 0, 0, 0.35) }
        }
      }
    }

    // Headshell: angled in toward the record, as a real one is, so the
    // stylus tracks the groove.
    Item {
      id: headshell
      x: 0
      y: arm.height / 2 - height / 2
      width: root.size * 0.115
      height: arm.tubeH * 2.4
      transform: Rotation { origin.x: headshell.width; origin.y: headshell.height / 2; angle: -14 }

      // Shell body, tapered toward the front.
      Rectangle {
        anchors.fill: parent
        anchors.leftMargin: parent.width * 0.12
        radius: 2
        antialiasing: true
        gradient: Gradient {
          GradientStop { position: 0.0; color: Qt.lighter(root.metal, 1.15) }
          GradientStop { position: 1.0; color: root.metalDark }
        }
        border.width: 1
        border.color: Qt.rgba(0, 0, 0, 0.45)
      }
      // Finger lift.
      Rectangle {
        x: 0
        y: -height * 0.35
        width: parent.width * 0.34
        height: Math.max(1.5, arm.tubeH * 0.55)
        radius: height / 2
        color: root.metal
        antialiasing: true
      }
      // Cartridge, in the accent colour: the one bright thing on the arm.
      Rectangle {
        x: parent.width * 0.16
        y: parent.height * 0.55
        width: parent.width * 0.5
        height: parent.height * 0.75
        radius: 1.5
        color: Color.accent
        border.width: 1
        border.color: Qt.darker(Color.accent, 1.6)
        antialiasing: true
      }
      // Stylus.
      Rectangle {
        x: parent.width * 0.22
        y: parent.height * 1.25
        width: Math.max(1, root.size * 0.006)
        height: Math.max(2, root.size * 0.02)
        color: Color.foreground
        antialiasing: true
      }
    }
  }
}
