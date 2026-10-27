import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Mindwtr popup panel. Owns all server IO for the plugin: the bar widget is a
// thin renderer of the counts this panel exposes. The panel stays mounted
// while closed, so the refresh timer keeps the badge fresh.
//
// Keyboard model (when the capture field is not focused):
//   Up/Down or k/j   move the row cursor
//   Enter / Space    open the selected task's details
//   d                mark the selected (or shown) task done
//   c or /           focus the capture field
//   r                refresh
//   g / G            jump to first / last row
//   Esc              back out of details, else close the panel
Panel {
  id: root
  moduleName: "mindwtr"
  ipcTarget: "mindwtr"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot, not this nested panel.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string scriptPath: Qt.resolvedUrl("mindwtr-api.sh").toString().replace(/^file:\/\//, "")

  // ---- server state -------------------------------------------------------
  property var summary: null
  property bool loading: false
  property string errorText: ""
  property string activeTab: "focus"

  property int selectedIndex: 0
  property bool detailsOpen: false
  property var detailTask: null
  property bool detailLoading: false
  property string detailError: ""

  // Partial detailTask objects (from the summary) may lack these fields, so
  // coerce once here rather than binding undefined into bool/string props.
  readonly property var detailChecklist: (detailTask && Array.isArray(detailTask.checklist)) ? detailTask.checklist : []
  readonly property var detailAttachments: (detailTask && Array.isArray(detailTask.attachments)) ? detailTask.attachments : []
  readonly property string detailDescription: (detailTask && detailTask.description) ? String(detailTask.description) : ""
  readonly property string detailTitle: (detailTask && detailTask.title) ? String(detailTask.title) : "\u2026"

  property alias captureText: captureField.text
  property bool capturing: false
  // Holds the text for the helper until the capture process has started, because
  // stdin can only be written to a running process.
  property string pendingCaptureText: ""
  property string toast: ""
  property bool toastIsError: false

  readonly property var tabs: [
    { key: "focus", label: "Focus" },
    { key: "inbox", label: "Inbox" },
    { key: "next", label: "Next" },
    { key: "waiting", label: "Waiting" },
    { key: "someday", label: "Someday" }
  ]

  readonly property int focusCount: summary ? (summary.counts.focus || 0) : 0
  readonly property int inboxCount: summary ? (summary.counts.inbox || 0) : 0
  readonly property int nextCount: summary ? (summary.counts.next || 0) : 0
  readonly property int waitingCount: summary ? (summary.counts.waiting || 0) : 0
  readonly property int somedayCount: summary ? (summary.counts.someday || 0) : 0

  readonly property int refreshSecs: Math.max(30, parseInt(setting("refreshIntervalSec", 120), 10) || 120)
  readonly property bool quickAddEnabled: setting("quickAdd", true) === true
  readonly property bool showCheckbox: setting("checkbox", true) === true
  readonly property var activeTasks: (summary && summary[activeTab]) ? summary[activeTab] : []

  readonly property string serverLabel: summary && summary.server !== "" ? summary.server : "Mindwtr"
  readonly property string statusText: {
    if (errorText !== "") return errorText
    if (loading && !summary) return "Loading\u2026"
    return "Focus " + focusCount + "  \u00b7  Inbox " + inboxCount + "  \u00b7  Next " + nextCount + "  \u00b7  Waiting " + waitingCount
  }

  // ---- lifecycle (mirrors the first-party popup panels) -------------------
  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
      keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- data ---------------------------------------------------------------
  function refresh() {
    if (summaryProc.running) return
    loading = true
    summaryProc.command = ["bash", root.scriptPath, "summary"]
    summaryProc.running = true
  }

  function handleSummary(raw) {
    loading = false
    var parsed = Model.parseSummary(raw)
    if (!parsed.ok) {
      errorText = Model.errorText(parsed.error)
      return
    }
    errorText = ""
    summary = parsed
    root.clampSelection()
  }

  function clampSelection() {
    var count = activeTasks.length
    if (count === 0) selectedIndex = 0
    else if (selectedIndex >= count) selectedIndex = count - 1
    else if (selectedIndex < 0) selectedIndex = 0
  }

  function selectTab(key) {
    activeTab = String(key)
    selectedIndex = 0
    detailsOpen = false
    detailTask = null
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function cycleTab(delta) {
    if (detailsOpen || tabs.length === 0) return
    var index = 0
    for (var i = 0; i < tabs.length; i++) if (tabs[i].key === activeTab) index = i
    index = (index + delta + tabs.length) % tabs.length
    selectTab(tabs[index].key)
  }

  function selectedTask() {
    if (detailsOpen) return detailTask
    return selectedIndex >= 0 && selectedIndex < activeTasks.length ? activeTasks[selectedIndex] : null
  }

  function moveSelection(delta) {
    if (detailsOpen) {
      detailFlick.contentY = Math.max(0, Math.min(detailFlick.contentHeight - detailFlick.height, detailFlick.contentY + delta * Style.space(48)))
      return
    }
    var count = activeTasks.length
    if (count === 0) return
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > count - 1) next = count - 1
    selectedIndex = next
    root.ensureVisible()
  }

  function ensureVisible() {
    var item = taskRepeater.itemAt(selectedIndex)
    if (!item || !listFlick) return
    var top = item.y
    var bottom = item.y + item.height
    if (top < listFlick.contentY) listFlick.contentY = top
    else if (bottom > listFlick.contentY + listFlick.height) listFlick.contentY = bottom - listFlick.height
  }

  function openTaskDetails(task) {
    if (!task || !task.id) return
    detailTask = task
    detailError = ""
    detailsOpen = true
    detailLoading = true
    taskProc.command = ["bash", root.scriptPath, "task", String(task.id)]
    taskProc.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function closeDetails() {
    detailsOpen = false
    detailTask = null
    detailError = ""
    detailLoading = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function handleTask(raw) {
    detailLoading = false
    var parsed = Model.parseTask(raw)
    if (!parsed.ok) {
      detailError = Model.errorText(parsed.error)
      return
    }
    detailTask = parsed.task
  }

  function showToast(message, isError) {
    toast = message
    toastIsError = isError === true
    toastTimer.restart()
  }

  function submitCapture() {
    if (!quickAddEnabled || capturing) return
    var text = String(captureText).replace(/^\s+|\s+$/g, "")
    if (text === "") return
    capturing = true
    // The text goes to the helper on stdin, never as an argument: a command line
    // is readable from /proc by any local process while the helper runs.
    pendingCaptureText = text
    captureProc.command = ["bash", root.scriptPath, "capture"]
    captureProc.running = true
  }

  function completeTask(task) {
    if (!task || !task.id || completeProc.running) return
    pendingCompleteId = String(task.id)
    completeProc.command = ["bash", root.scriptPath, "complete", String(task.id)]
    completeProc.running = true
  }

  function openAttachment(uri) {
    var value = String(uri || "")
    if (value === "") return
    if (value.indexOf("http://") !== 0 && value.indexOf("https://") !== 0 && value.indexOf("file://") !== 0) return
    // Handed to xdg-open as a single argv element rather than as text spliced
    // into a shell string, so no quoting can be got wrong.
    openProc.command = ["xdg-open", value]
    openProc.running = true
  }

  property string pendingCompleteId: ""

  // ---- IO -----------------------------------------------------------------
  Process {
    id: summaryProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleSummary(text)
    }
    onRunningChanged: if (!running && root.loading) root.loading = false
  }

  Process {
    id: taskProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleTask(text)
    }
    onRunningChanged: if (!running && root.detailLoading) root.detailLoading = false
  }

  Process {
    id: captureProc
    // The helper reads the task text from stdin so it never reaches a command
    // line. Writes go through onStarted because write() is a no-op while the
    // process is not running yet.
    stdinEnabled: true
    onStarted: {
      if (root.pendingCaptureText === "") return
      var text = root.pendingCaptureText
      root.pendingCaptureText = ""
      captureProc.write(text + "\n")
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseMutation(text)
        if (parsed.ok) {
          root.captureText = ""
          root.showToast("Captured", false)
          Qt.callLater(root.refresh)
        } else {
          root.showToast(Model.errorText(parsed.error), true)
        }
      }
    }
    onRunningChanged: if (!running) {
      root.capturing = false
      if (root.pendingCaptureText !== "") root.pendingCaptureText = ""
    }
  }

  Process {
    id: openProc
  }

  Process {
    id: completeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseMutation(text)
        if (parsed.ok) {
          root.showToast("Completed", false)
          if (root.detailsOpen && root.detailTask && String(root.detailTask.id) === root.pendingCompleteId)
            root.closeDetails()
          Qt.callLater(root.refresh)
        } else {
          root.showToast(Model.errorText(parsed.error), true)
        }
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshSecs * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: toastTimer
    interval: 2600
    onTriggered: { root.toast = ""; root.toastIsError = false }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  // ---- UI -----------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(bodyColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: captureField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveSelection(dy)
        else if (dx !== 0) root.cycleTab(dx)
      }
      onActivateRequested: if (!root.detailsOpen) root.openTaskDetails(root.selectedTask())
      onCloseRequested: { if (root.detailsOpen) root.closeDetails(); else root.close() }
      onTabRequested: function(direction) { if (!root.detailsOpen) root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t)
        var lower = key.toLowerCase()
        if (lower === "d") root.completeTask(root.selectedTask())
        else if (lower === "c" || key === "/") { captureField.forceActiveFocus() }
        else if (lower === "r") root.refresh()
        else if (key === "g") { root.selectedIndex = 0; root.ensureVisible() }
        else if (key === "G") { root.selectedIndex = Math.max(0, root.activeTasks.length - 1); root.ensureVisible() }
        else if (key >= "1" && key <= "9") {
          var tabIndex = parseInt(key, 10) - 1
          if (tabIndex < root.tabs.length) root.selectTab(root.tabs[tabIndex].key)
        }
      }

      Column {
        id: bodyColumn
        width: parent.width
        spacing: Style.space(10)

        // ---- header
        Item {
          width: parent.width
          height: Style.space(26)

          Rectangle {
            id: backButton
            visible: root.detailsOpen
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(22)
            height: Style.space(22)
            radius: Math.min(5, Style.cornerRadius)
            color: backMouse.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

            Text {
              anchors.centerIn: parent
              text: "\uf060"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            MouseArea {
              id: backMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.closeDetails()
            }
          }

          Text {
            id: titleText
            anchors.left: root.detailsOpen ? backButton.right : parent.left
            anchors.leftMargin: root.detailsOpen ? Style.space(6) : 0
            anchors.verticalCenter: parent.verticalCenter
            text: root.detailsOpen ? "Task details" : "Mindwtr"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            textFormat: Text.PlainText
          }

          Text {
            visible: !root.detailsOpen
            anchors.left: titleText.right
            anchors.leftMargin: Style.space(8)
            anchors.right: refreshButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.serverLabel
            color: Color.muted
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
            elide: Text.ElideRight
          }

          Rectangle {
            id: refreshButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(22)
            height: Style.space(22)
            radius: Math.min(5, Style.cornerRadius)
            color: refreshMouse.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

            Text {
              anchors.centerIn: parent
              text: "\uf021"
              color: root.loading ? Color.muted : root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            MouseArea {
              id: refreshMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.refresh()
            }
          }
        }

        // ---- bucket tabs
        Row {
          visible: !root.detailsOpen
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.tabs

            Rectangle {
              required property var modelData
              required property int index
              readonly property bool selected: root.activeTab === modelData.key
              readonly property int count: root.summary && root.summary.counts ? (root.summary.counts[modelData.key] || 0) : 0

              width: tabContent.implicitWidth + Style.space(16)
              height: Style.space(24)
              radius: Style.cornerRadius
              color: tabMouse.containsMouse && !selected
                ? Style.hoverFillFor(root.bar.foreground, Color.accent)
                : (selected ? Util.alpha(Color.accent, 0.18) : "transparent")

              Row {
                id: tabContent
                anchors.centerIn: parent
                spacing: Style.space(5)

                Text {
                  text: modelData.label
                  color: selected ? Color.accent : root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: selected
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  visible: count > 0
                  text: String(count)
                  color: selected ? Color.accent : Color.muted
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                id: tabMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectTab(modelData.key)
              }
            }
          }
        }

        // ---- error / toast line
        Text {
          visible: text !== ""
          width: parent.width
          text: root.errorText !== "" ? root.errorText : root.toast
          color: root.errorText !== "" || root.toastIsError ? Color.urgent : Color.muted
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
          elide: Text.ElideRight
        }

        // ---- task list
        Flickable {
          id: listFlick
          visible: !root.detailsOpen
          width: parent.width
          height: Math.min(listColumn.implicitHeight, Style.space(360))
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: listColumn
            width: listFlick.width
            spacing: Style.space(2)

            Repeater {
              id: taskRepeater
              model: root.activeTasks

              Rectangle {
                required property var modelData
                required property int index
                readonly property bool selected: index === root.selectedIndex
                readonly property bool overdue: Model.isOverdue(modelData)
                readonly property string meta: Model.subtitle(modelData)

                width: listColumn.width
                height: taskColumn.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: selected
                  ? Util.alpha(Color.accent, 0.16)
                  : (rowMouse.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent")

                Row {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.space(8)

                  Rectangle {
                    id: marker
                    width: Style.space(16)
                    height: width
                    radius: Math.min(4, Style.cornerRadius)
                    border.width: root.showCheckbox ? 1 : 0
                    border.color: Util.alpha(root.bar.foreground, 0.35)
                    color: "transparent"
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      anchors.centerIn: parent
                      text: modelData.focused
                        ? "\uf005"
                        : (root.showCheckbox ? (markerMouse.containsMouse ? "\uf00c" : "") : "\uf111")
                      color: modelData.focused ? Color.accent : (markerMouse.containsMouse ? Color.accent : Color.muted)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      textFormat: Text.PlainText
                    }

                    MouseArea {
                      id: markerMouse
                      anchors.fill: parent
                      enabled: root.showCheckbox
                      hoverEnabled: true
                      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                      onClicked: root.completeTask(modelData)
                    }
                  }

                  Column {
                    id: taskColumn
                    width: parent.width - Style.space(30)
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      text: modelData.title
                      color: overdue ? Color.urgent : root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      font.bold: selected
                    }

                    Text {
                      visible: meta !== ""
                      width: parent.width
                      text: meta
                      color: overdue ? Color.urgent : Color.muted
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                    }
                  }
                }

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.selectedIndex = index
                    root.openTaskDetails(modelData)
                  }
                }
              }
            }

            Text {
              visible: root.activeTasks.length === 0
              width: listColumn.width
              height: Style.space(64)
              text: root.loading ? "Loading\u2026"
                : root.errorText !== "" ? "No data"
                : "Nothing in " + root.activeTab
              color: Color.muted
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              textFormat: Text.PlainText
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
            }
          }
        }

        // ---- details
        Flickable {
          id: detailFlick
          visible: root.detailsOpen
          width: parent.width
          height: Math.min(detailColumn.implicitHeight, Style.space(380))
          contentWidth: width
          contentHeight: detailColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: detailColumn
            width: detailFlick.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: root.detailTitle
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
            }

            Text {
              visible: root.detailLoading
              width: parent.width
              text: "Loading details\u2026"
              color: Color.muted
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
              font.italic: true
            }

            Text {
              visible: root.detailError !== ""
              width: parent.width
              text: root.detailError
              color: Color.urgent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
            }

            Repeater {
              model: Model.detailRows(root.detailTask)

              Item {
                required property var modelData
                width: detailColumn.width
                height: Math.max(labelItem.implicitHeight, valueItem.implicitHeight)

                Text {
                  id: labelItem
                  anchors.left: parent.left
                  anchors.top: parent.top
                  width: Style.space(76)
                  text: modelData.label
                  color: Color.muted
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  textFormat: Text.PlainText
                }

                Text {
                  id: valueItem
                  anchors.left: labelItem.right
                  anchors.right: parent.right
                  anchors.top: parent.top
                  text: modelData.value
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                }
              }
            }

            // ---- description
            Rectangle {
              visible: root.detailDescription !== ""
              width: parent.width
              height: Style.spacing.hairline
              color: root.bar.foreground
              opacity: 0.12
            }

            Text {
              visible: root.detailDescription !== ""
              width: parent.width
              text: root.detailDescription
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
            }

            // ---- checklist
            Column {
              visible: root.detailChecklist.length > 0
              width: parent.width
              spacing: Style.space(3)

              Repeater {
                model: root.detailChecklist

                Row {
                  required property var modelData
                  spacing: Style.space(6)

                  Text {
                    text: modelData.done ? "\uf14a" : "\uf096"
                    color: modelData.done ? Color.accent : Color.muted
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: modelData.title
                    color: modelData.done ? Color.muted : root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.strikeout: modelData.done
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }

            // ---- attachments
            Column {
              visible: root.detailAttachments.length > 0
              width: parent.width
              spacing: Style.space(3)

              Repeater {
                model: root.detailAttachments

                Row {
                  required property var modelData
                  spacing: Style.space(6)

                  Text {
                    text: "\uf0c1"
                    color: Color.muted
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: modelData.title !== "" ? modelData.title : modelData.uri
                    color: Color.accent
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openAttachment(modelData.uri)
                  }
                }
              }
            }

            Text {
              width: parent.width
              text: "d done  \u00b7  Esc back"
              color: Color.muted
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
            }
          }
        }

        // ---- quick capture
        Row {
          visible: root.quickAddEnabled && !root.detailsOpen
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: captureField
            width: parent.width - addButton.width - Style.space(8)
            placeholderText: "Capture to Inbox\u2026  (@context, #project, tomorrow)"
            foreground: root.bar.foreground
            enabled: !root.capturing

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.submitCapture()
                event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                event.accepted = true
                keyCatcher.forceActiveFocus()
              }
            }
          }

          Rectangle {
            id: addButton
            width: Style.space(30)
            height: captureField.height
            radius: Style.cornerRadius
            color: addMouse.containsMouse && captureField.text !== ""
              ? Style.hoverFillFor(root.bar.foreground, Color.accent)
              : "transparent"
            border.width: 1
            border.color: Util.alpha(root.bar.foreground, 0.25)

            Text {
              anchors.centerIn: parent
              text: root.capturing ? "\u2026" : "\uf067"
              color: captureField.text !== "" ? root.bar.foreground : Color.muted
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            MouseArea {
              id: addMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.submitCapture()
            }
          }
        }

        // ---- footer
        Text {
          width: parent.width
          text: {
            if (root.errorText !== "" && !root.summary) return "Set the server in ~/.config/omarchy/mindwtr.json"
            if (root.detailsOpen) return ""
            var hints = "\u2191\u2193 move  \u00b7  Enter details  \u00b7  d done  \u00b7  c capture"
            if (root.summary && root.summary.fetchedAt !== "")
              hints += "  \u00b7  " + root.summary.fetchedAt.replace("T", " ").replace("Z", " UTC")
            return hints
          }
          color: Color.muted
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
          elide: Text.ElideRight
        }
      }
    }
  }
}
