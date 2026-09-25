import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import qs.Ui as Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "gruut.orca-status"
  ipcTarget: "orca-status"
  manageIpc: false

  property var data: ({})
  property var worktrees: []
  property var projects: []
  property string filterText: ""
  property string statusText: ""
  property bool statusIsError: false
  property bool loaded: false
  property bool offline: false
  property string semaphore: "gray"
  property int cursorIndex: 0
  property bool cursorActive: false
  property string expandedWorktreeId: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color success: Qt.rgba(0.65, 0.89, 0.63, 1)
  readonly property color warning: Qt.rgba(0.98, 0.70, 0.53, 1)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var rows: Model.filteredWorktrees(worktrees, filterText)
  readonly property var currentRow: cursorIndex >= 0 && cursorIndex < rows.length ? rows[cursorIndex] : null
  readonly property int refreshIntervalSec: Math.max(3, setting("refreshIntervalSec", 12))
  readonly property bool showWhenIdle: setting("showWhenIdle", false) === true
  readonly property string orcaCliPath: String(setting("orcaCliPath", "") || "")
  readonly property string script: Qt.resolvedUrl("orca-status.py").toString().replace("file://", "")
  readonly property var palette: ({ urgent: urgent, warning: warning, success: success, dim: dim })
  property int summaryBlocked: 0
  property int summaryWaiting: 0
  property int summaryWorking: 0

  readonly property bool hasBlocked: summaryBlocked > 0
  readonly property bool hasWaiting: summaryWaiting > 0
  readonly property bool hasWorking: summaryWorking > 0
  readonly property bool hasLiveActivity: hasBlocked || hasWaiting || hasWorking
  readonly property color statusColor: offline
    ? dim
    : (hasBlocked ? urgent : (hasWaiting ? warning : (hasWorking ? success : dim)))
  readonly property bool barVisible: Model.shouldShowBar({
    loaded: loaded,
    offline: offline,
    summary: { blocked: summaryBlocked, waiting: summaryWaiting, working: summaryWorking },
    worktrees: worktrees
  }, showWhenIdle)

  function refresh() {
    if (!fetchProc.running) fetchProc.running = true
  }

  function setStatus(text, isError) {
    statusText = text
    statusIsError = isError === true
    statusClear.restart()
  }

  function applyPayload(result) {
    loaded = true
    if (!result.ok) {
      offline = result.offline === true
      data = result
      worktrees = []
      projects = []
      semaphore = "gray"
      if (result.error) setStatus(result.error, true)
      return
    }
    offline = false
    data = result
    worktrees = result.worktrees || []
    projects = result.projects || []
    semaphore = result.semaphore || "gray"
    summaryBlocked = result.summary ? (result.summary.blocked || 0) : 0
    summaryWaiting = result.summary ? (result.summary.waiting || 0) : 0
    summaryWorking = result.summary ? (result.summary.working || 0) : 0
    clampCursor()
  }

  function moveCursor(delta) {
    cursorActive = true
    if (rows.length === 0) return
    cursorIndex = Math.max(0, Math.min(rows.length - 1, cursorIndex + delta))
    scrollCursorIntoView()
  }

  function setCursor(index) {
    cursorActive = true
    cursorIndex = index
  }

  function toggleExpanded(row) {
    if (!row) return
    expandedWorktreeId = expandedWorktreeId === row.worktreeId ? "" : row.worktreeId
  }

  function focusWorktree(row) {
    if (!row) return
    if (!row.terminalHandle) {
      setStatus("No live terminal to focus for this workspace.", true)
      return
    }
    switchProc.pendingLabel = Model.rowTitle(row)
    var argv = ["python3", root.script, "switch", "--terminal", String(row.terminalHandle)]
    if (orcaCliPath !== "") argv = argv.concat(["--cli", orcaCliPath])
    switchProc.command = argv
    switchProc.running = true
  }

  function openPath(row) {
    if (!row || !row.path) {
      setStatus("No project path for this workspace.", true)
      return
    }
    Quickshell.execDetached(["xdg-open", row.path])
    setStatus("Opened " + row.path, false)
  }

  function activateRow(row) {
    if (!row) return
    if (expandedWorktreeId !== row.worktreeId && row.agents && row.agents.length > 0) {
      expandedWorktreeId = row.worktreeId
      return
    }
    focusWorktree(row)
  }

  function clampCursor() {
    if (rows.length === 0) { cursorIndex = 0; return }
    cursorIndex = Math.max(0, Math.min(rows.length - 1, cursorIndex))
  }

  function focusSearch(seed) {
    if (seed !== undefined && seed !== "") search.text = seed
    search.forceActiveFocus()
    search.cursorPosition = search.text.length
  }

  function leaveSearch() {
    keyCatcher.forceActiveFocus()
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (!worktreeColumn || cursorIndex < 0 || cursorIndex >= worktreeColumn.children.length) return
    scrollItemIntoView(worktreeColumn.children[cursorIndex])
  }

  function handleTextKey(text) {
    if (text === "/") { focusSearch(""); return }
    if (text >= "0" && text <= "9") { focusSearch(search.text + text); return }
    if (text === "r" || text === "R") { refresh(); setStatus("Refreshed.", false); return }
    if (text === "o" || text === "O") { openPath(currentRow); return }
    if (text === "f" || text === "F") { focusWorktree(currentRow); return }
    if (text === "e" || text === "E") { toggleExpanded(currentRow); return }
  }

  Process {
    id: fetchProc
    command: {
      var argv = ["python3", root.script]
      if (root.orcaCliPath !== "") argv = argv.concat(["--cli", root.orcaCliPath])
      return argv
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPayload(Model.parseResult(text))
    }
  }

  Process {
    id: switchProc
    property string pendingLabel: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Model.parseResult(text)
        root.setStatus(Model.switchResultText(result), !result.ok)
        if (result.ok) root.close()
      }
    }
  }

  Timer {
    id: pollTimer
    interval: {
      if (root.opened) return 2500
      if (root.hasBlocked) return 4000
      return root.refreshIntervalSec * 1000
    }
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer { id: statusClear; interval: 4000; onTriggered: root.statusText = "" }

  IpcHandler {
    target: "orca-status"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  visible: barVisible
  implicitWidth: buttonRow.implicitWidth
  implicitHeight: buttonRow.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    expandedWorktreeId = ""
    search.text = ""
    if (panelFlick) panelFlick.contentY = 0
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Item {
    id: buttonRow
    implicitWidth: button.implicitWidth + Style.space(4)
    implicitHeight: button.implicitHeight

    WidgetButton {
      id: button
      anchors.centerIn: parent
      bar: root.bar
      text: "󰚩"
      tooltipText: Model.barTooltip(data)
      useActiveColor: hasLiveActivity
      active: hasBlocked || hasWaiting || hasWorking
      horizontalMargin: 8.5
      onPressed: function(code) {
        if (code === Qt.RightButton) root.refresh()
        else root.toggle()
      }
    }

    Rectangle {
      visible: loaded && !offline
      width: 10
      height: 10
      radius: 5
      anchors.right: button.right
      anchors.top: button.top
      anchors.rightMargin: 2
      anchors.topMargin: 1
      color: root.statusColor
      border.width: 1
      border.color: bar ? bar.background : Qt.darker(foreground, 1.2)
    }
  }

  KeyboardPanel {
    id: panel
    bar: root.bar
    anchorItem: button
    owner: root
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: search.activeFocus

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) {
          if (!root.cursorActive) { root.cursorActive = true; return }
          root.moveCursor(dy)
        }
      }
      onActivateRequested: root.activateRow(root.currentRow)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { root.handleTextKey(t) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: "Orca Status"
            meta: root.offline ? "Offline" : (root.loaded ? Model.headline(root.data) : "Reading status")
            detail: root.offline ? "" : Model.stateLabel(root.data.summary ? root.data.summary.overallState : "inactive")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Row {
                spacing: Style.space(6)
                Text {
                  textFormat: Text.PlainText
                  text: "󰚩"
                  color: root.offline ? root.dim : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
                Rectangle {
                  visible: !root.offline
                  width: Style.space(8)
                  height: Style.space(8)
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: Model.semaphoreColor(root.semaphore, root.palette)
                }
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: "󰑐"
                tooltipText: "Refresh (r)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.refresh()
              }
            }
          }

          Ui.TextField {
            id: search
            width: parent.width
            placeholderText: "Filter by project, branch, or path…"
            foreground: root.foreground
            accent: root.accent
            font.family: root.fontFamily
            onTextChanged: {
              root.filterText = text
              root.cursorIndex = 0
            }
            Keys.onEscapePressed: {
              if (text !== "") text = ""
              else root.leaveSearch()
            }
            Keys.onDownPressed: { root.leaveSearch(); root.cursorActive = true }
            Keys.onReturnPressed: { root.leaveSearch(); root.cursorActive = true; root.activateRow(root.currentRow) }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.statusText !== ""
            width: parent.width
            text: root.statusText
            color: root.statusIsError ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSectionHeader {
            text: "PROJECTS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.projects
            delegate: ProjectRow {
              width: column.width
              project: modelData
              worktrees: root.worktrees
              foreground: root.foreground
              fontFamily: root.fontFamily
              palette: root.palette
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.projects.length === 0
            width: parent.width
            text: root.offline ? "Orca is not running." : "No projects registered."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          PanelSectionHeader {
            text: "WORKSPACES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            textFormat: Text.PlainText
            visible: root.rows.length === 0
            width: parent.width
            topPadding: Style.space(8)
            bottomPadding: Style.space(8)
            text: !root.loaded
              ? "Reading Orca status…"
              : (root.filterText !== ""
                ? "Nothing matches \"" + root.filterText + "\"."
                : "No workspaces found.")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Column {
            id: worktreeColumn
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.rows
              delegate: WorktreeRow {
                width: worktreeColumn.width
                worktree: modelData
                index: index
                selected: root.cursorActive && root.cursorIndex === index
                expanded: root.expandedWorktreeId === modelData.worktreeId
                foreground: root.foreground
                fontFamily: root.fontFamily
                palette: root.palette
                onClicked: {
                  root.setCursor(index)
                  root.activateRow(modelData)
                }
                onExpandRequested: {
                  root.setCursor(index)
                  root.toggleExpanded(modelData)
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Flow {
            width: parent.width
            spacing: Style.space(10)
            KeyHint { keyLabel: "↑↓"; action: "move" }
            KeyHint { keyLabel: "⏎"; action: "expand / focus" }
            KeyHint { keyLabel: "f"; action: "focus in Orca" }
            KeyHint { keyLabel: "o"; action: "open path" }
            KeyHint { keyLabel: "e"; action: "expand agents" }
            KeyHint { keyLabel: "/"; action: "filter" }
          }
        }
      }
    }
  }

  component ProjectRow: Rectangle {
    property var project
    property var worktrees
    property var palette
    property color foreground
    property string fontFamily

    radius: Style.cornerRadius
    color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.04)
    implicitHeight: row.implicitHeight + Style.space(12)

    RowLayout {
      id: row
      anchors.fill: parent
      anchors.margins: Style.space(8)
      spacing: Style.space(8)

      Rectangle {
        width: Style.space(8)
        height: Style.space(8)
        radius: width / 2
        color: project.badgeColor || root.dim
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          text: project.displayName || "Project"
          color: foreground
          font.family: fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          text: project.activeWorktreeCount + " active · " + project.worktreeCount + " workspace" + (project.worktreeCount === 1 ? "" : "s")
          color: root.dim
          font.family: fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Rectangle {
        width: Style.space(8)
        height: Style.space(8)
        radius: width / 2
        color: Model.stateColor(project.worstState, palette)
      }
    }
  }

  component WorktreeRow: Rectangle {
    id: worktreeRow
    property var worktree
    property int index
    property bool selected
    property bool expanded
    property var palette
    property color foreground
    property string fontFamily
    signal clicked()
    signal expandRequested()

    radius: Style.cornerRadius
    color: selected
      ? Qt.rgba(foreground.r, foreground.g, foreground.b, 0.10)
      : Qt.rgba(foreground.r, foreground.g, foreground.b, 0.04)
    implicitHeight: content.implicitHeight + Style.space(12)

    Column {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: Style.space(8)
      spacing: Style.space(6)

      MouseArea {
        width: parent.width
        height: header.implicitHeight
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: worktreeRow.clicked()
      }

      RowLayout {
        id: header
        width: parent.width
        spacing: Style.space(8)

        Rectangle {
          width: Style.space(8)
          height: Style.space(8)
          radius: width / 2
          color: Model.stateColor(worktree.state, palette)
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            text: Model.rowTitle(worktree)
            color: foreground
            font.family: fontFamily
            font.pixelSize: Style.font.body
            font.bold: selected
            elide: Text.ElideRight
            Layout.fillWidth: true
          }

          Text {
            textFormat: Text.PlainText
            text: Model.rowMeta(worktree)
            color: root.dim
            font.family: fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            Layout.fillWidth: true
          }
        }

        Text {
          textFormat: Text.PlainText
          text: Model.stateLabel(worktree.state)
          color: Model.stateColor(worktree.state, palette)
          font.family: fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: String(worktree.summary || "") !== ""
        text: worktree.summary
        color: root.dim
        font.family: fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }

      Column {
        width: parent.width
        visible: expanded && worktree.agents && worktree.agents.length > 0
        spacing: Style.space(4)

        Repeater {
          model: worktree.agents
          delegate: Rectangle {
            width: parent.width
            radius: Style.cornerRadius
            color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.05)
            implicitHeight: agentRow.implicitHeight + Style.space(8)

            RowLayout {
              id: agentRow
              anchors.fill: parent
              anchors.margins: Style.space(6)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: Model.agentGlyph(modelData.agentType, modelData.displayLabel)
                color: foreground
                font.family: fontFamily
                font.pixelSize: Style.font.body
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: Model.agentLabel(modelData) + (modelData.toolName ? " · " + modelData.toolName : "")
                  color: foreground
                  font.family: fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: modelData.prompt || modelData.lastAssistantMessage || ""
                  color: root.dim
                  font.family: fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }
              }

              Text {
                textFormat: Text.PlainText
                text: Model.stateLabel(modelData.state)
                color: Model.stateColor(modelData.state, palette)
                font.family: fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }
        }
      }
    }
  }

  component KeyHint: Row {
    property string keyLabel: ""
    property string action: ""
    spacing: Style.space(4)

    Text {
      textFormat: Text.PlainText
      text: parent.keyLabel
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      textFormat: Text.PlainText
      text: parent.action
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
