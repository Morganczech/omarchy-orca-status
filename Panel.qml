import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import qs.Ui as Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "gruut.orca-status"
  ipcTarget: "orca-status"
  manageIpc: false

  property var payload: ({})
  property var worktrees: []
  property var projects: []
  property string filterText: ""
  readonly property var visibleProjects: projects.filter(function(project) { return projectHasPresence(project) })
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
  readonly property color success: Color.accent
  readonly property color warning: Qt.rgba(0.98, 0.70, 0.53, 1)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var rows: Model.filteredWorktrees(worktrees, filterText)
  readonly property var currentRow: cursorIndex >= 0 && cursorIndex < rows.length ? rows[cursorIndex] : null
  readonly property int refreshIntervalSec: Math.max(3, setting("refreshIntervalSec", 12))
  readonly property bool showWhenIdle: setting("showWhenIdle", true) !== false
  readonly property string orcaCliPath: String(setting("orcaCliPath", "") || "")
  readonly property string script: Qt.resolvedUrl("orca-status.py").toString().replace("file://", "")
  property bool pinned: false

  Component.onCompleted: {
    pinned = setting("keepOpen", false) === true
    var savedHeight = Number(setting("panelHeight", 0))
    if (savedHeight > 0) userPanelHeight = savedHeight
  }

  function saveSetting(name, value) {
    var entry = { id: moduleName }
    for (var existing in settings) if (existing !== "id") entry[existing] = settings[existing]
    entry[name] = value
    settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, entry)
  }

  function setKeepOpen(value) {
    pinned = value === true
    saveSetting("keepOpen", pinned)
    placePanelBody()
    if (!pinned) forceClose()
  }

  function close() { controller.hide() }

  function forceClose() { controller.hide() }

  function toggle() { opened ? forceClose() : open() }

  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    forceClose()
    Qt.callLater(function() { popoutSwitchClosing = false })
  }
  readonly property var palette: ({ urgent: urgent, warning: warning, success: success, dim: dim })
  property int summaryBlocked: 0
  property int summaryWaiting: 0
  property int summaryWorking: 0

  readonly property bool hasBlocked: summaryBlocked > 0
  readonly property bool hasWaiting: summaryWaiting > 0
  readonly property bool hasWorking: summaryWorking > 0 || Model.hasActiveWorktrees(worktrees) || semaphore === "green"
  readonly property bool hasLiveActivity: hasBlocked || hasWaiting || hasWorking
  readonly property string barIcon: Model.barIconForWorktrees(worktrees)
  readonly property color statusColor: offline
    ? dim
    : (hasBlocked ? urgent : (hasWaiting ? warning : (hasWorking ? success : dim)))
  readonly property color iconColor: offline
    ? dim
    : (hasBlocked ? urgent : (hasWaiting ? warning : (hasWorking ? success : foreground)))
  readonly property bool barVisible: Model.shouldShowBar({
    loaded: loaded,
    offline: offline,
    summary: { blocked: summaryBlocked, waiting: summaryWaiting, working: summaryWorking },
    worktrees: worktrees
  }, showWhenIdle)

  function refresh() {
    if (!fetchProc.running) fetchProc.running = true
  }

  function projectHasPresence(project) {
    if (!project) return false
    if ((project.activeWorktreeCount || 0) > 0) return true
    var rows = Model.worktreesForProject(project, worktrees)
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (!row) continue
      if (row.liveTerminalCount > 0) return true
      if (row.agents && row.agents.length > 0) return true
      if (row.state === "working" || row.state === "waiting" || row.state === "blocked") return true
    }
    return false
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
      payload = result
      worktrees = []
      projects = []
      semaphore = "gray"
      summaryBlocked = 0
      summaryWaiting = 0
      summaryWorking = 0
      if (result.error) setStatus(result.error, true)
      return
    }
    offline = false
    payload = result
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

  function focusHandle(handle, label) {
    if (!handle) {
      setStatus("No live terminal to focus.", true)
      return
    }
    switchProc.pendingLabel = label || "workspace"
    var argv = ["python3", root.script, "switch", "--terminal", String(handle)]
    if (orcaCliPath !== "") argv = argv.concat(["--cli", orcaCliPath])
    switchProc.command = argv
    switchProc.running = true
  }

  function focusWorktree(row) {
    if (!row) return
    focusHandle(row.terminalHandle, Model.rowTitle(row))
  }

  function focusAgent(agent) {
    if (!agent) return
    focusHandle(agent.terminalHandle, Model.agentLabel(agent))
  }

  function openPath(row) {
    if (!row || !row.path) {
      setStatus("No project path for this workspace.", true)
      return
    }
    Quickshell.execDetached(["xdg-open", row.path])
    setStatus("Opened " + row.path, false)
  }

  function openChangedFiles(row) {
    if (!row || !row.path) {
      setStatus("No project path for this workspace.", true)
      return
    }
    actionProc.pendingOkText = "Opened changed files in Orca."
    var argv = ["python3", root.script, "open-changed", "--path", String(row.path)]
    if (orcaCliPath !== "") argv = argv.concat(["--cli", orcaCliPath])
    actionProc.command = argv
    actionProc.running = true
  }

  function launchOrca() {
    actionProc.pendingOkText = "Starting Orca…"
    var argv = ["python3", root.script, "launch"]
    if (orcaCliPath !== "") argv = argv.concat(["--cli", orcaCliPath])
    actionProc.command = argv
    actionProc.running = true
  }

  function activateRow(row) {
    if (!row) return
    if (row.agents && row.agents.length > 0) {
      toggleExpanded(row)
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
    if (text === "d" || text === "D") { openChangedFiles(currentRow); return }
  }

  Process {
    id: fetchProc
    command: root.orcaCliPath !== ""
      ? ["python3", root.script, "--cli", root.orcaCliPath]
      : ["python3", root.script]
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

  Process {
    id: actionProc
    property string pendingOkText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Model.parseResult(text)
        if (result.ok) root.setStatus(actionProc.pendingOkText, false)
        else root.setStatus(result.error || "Action failed.", true)
        root.refresh()
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

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    expandedWorktreeId = ""
    search.text = ""
    if (panelFlick) panelFlick.contentY = 0
    refresh()
    if (!pinned) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barIcon !== "" ? root.barIcon : "󰆍"
    tooltipText: loaded ? Model.barTooltip(payload) : "Orca Status"
    useActiveColor: hasLiveActivity
    active: hasLiveActivity
    activeColor: root.iconColor
    foreground: hasLiveActivity ? root.iconColor : (bar ? bar.barForeground : Color.foreground)
    horizontalMargin: 8.5
    onPressed: function(code) {
      if (code === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  // Count badge: number of agents that need attention (blocked + waiting).
  Rectangle {
    id: attentionBadge
    readonly property int count: root.summaryBlocked + root.summaryWaiting
    visible: count > 0
    z: 100
    anchors.right: button.right
    anchors.top: button.top
    anchors.topMargin: Style.space(2)
    width: Math.max(height, badgeText.implicitWidth + Style.space(4))
    height: Style.space(11)
    radius: height / 2
    color: root.summaryBlocked > 0 ? root.urgent : root.warning
    border.width: 1
    border.color: Color.background

    Text {
      id: badgeText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: attentionBadge.count > 9 ? "9+" : String(attentionBadge.count)
      color: Color.background
      font.family: root.fontFamily
      font.pixelSize: Style.space(8)
      font.bold: true
    }
  }

  property real userPanelHeight: 0
  property Item popupHost: null

  function placePanelBody() {
    if (!keyCatcher || !resizeGrip) return
    var host = stickHost
    if (!host) return
    keyCatcher.parent = host
    resizeGrip.parent = host
  }

  KeyboardPanel {
    id: panel
    bar: root.bar
    anchorItem: button
    owner: root
    open: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: root.userPanelHeight > 0
      ? panel.cappedContentHeight(root.userPanelHeight)
      : panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    Component.onCompleted: {
      root.popupHost = keyCatcher.parent
      root.placePanelBody()
    }
    onOpenChanged: if (open) root.placePanelBody()

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
      onCloseRequested: root.forceClose()
      onTextKey: function(t) { root.handleTextKey(t) }

      Flickable {
        id: panelFlick
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(12)
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar {
          id: panelScroll
          policy: ScrollBar.AsNeeded
          implicitWidth: Style.space(6)
          contentItem: Rectangle {
            implicitWidth: Style.space(6)
            radius: width / 2
            color: Util.alpha(root.foreground, panelScroll.pressed ? 0.7 : 0.45)
          }
        }

        Column {
          id: column
          width: panelFlick.width - (panelScroll.visible ? panelScroll.width + Style.space(4) : 0)
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: "Orca Status"
            meta: root.offline ? "Offline" : (root.loaded ? Model.headline(root.payload) : "Reading status")
            detail: ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󰚩"
                color: root.offline ? root.dim : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(4)

                PanelActionButton {
                  iconText: "󰤱"
                  tooltipText: root.pinned ? "Unpin" : "Keep open"
                  hasCursor: root.pinned
                  foreground: root.foreground
                  hoverColor: root.pinned ? root.accent : root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.setKeepOpen(!root.pinned)
                }

                PanelActionButton {
                  iconText: "󰑐"
                  tooltipText: "Refresh (r)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.refresh()
                }
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
            visible: root.visibleProjects.length > 0
            text: "PROJECTS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)
            visible: root.visibleProjects.length > 0

            Repeater {
              model: root.visibleProjects
              delegate: ProjectChip {
                project: modelData
                foreground: root.foreground
                fontFamily: root.fontFamily
                selected: root.filterText !== "" && root.filterText === (modelData.displayName || "")
                onClicked: {
                  var name = modelData.displayName || ""
                  if (name !== "" && root.filterText === name) search.text = ""
                  else search.text = name
                  root.cursorActive = true
                  root.cursorIndex = 0
                }
              }
            }
          }

          Column {
            width: parent.width
            visible: root.offline && root.visibleProjects.length === 0
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Orca is not running."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Ui.Button {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "Start Orca"
              onClicked: root.launchOrca()
            }
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
                onFocusRequested: {
                  root.setCursor(index)
                  root.focusWorktree(modelData)
                }
                onOpenRequested: {
                  root.setCursor(index)
                  root.openPath(modelData)
                }
                onDiffRequested: {
                  root.setCursor(index)
                  root.openChangedFiles(modelData)
                }
                onAgentClicked: function(agent) {
                  root.setCursor(index)
                  root.focusAgent(agent)
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Flow {
            width: parent.width
            spacing: Style.space(10)
            KeyHint { keyLabel: "↑↓"; action: "move" }
            KeyHint { keyLabel: "⏎"; action: "expand" }
            KeyHint { keyLabel: "f"; action: "focus in Orca" }
            KeyHint { keyLabel: "o"; action: "open path" }
            KeyHint { keyLabel: "d"; action: "changed files" }
            KeyHint { keyLabel: "e"; action: "expand agents" }
            KeyHint { keyLabel: "/"; action: "filter" }
          }
        }
      }

      MouseArea {
        id: resizeGrip
        z: 2
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Style.space(12)
        hoverEnabled: true
        cursorShape: Qt.SizeVerCursor
        property real originY: 0
        property real originHeight: 0
        onPressed: function(mouse) {
          var point = mapToGlobal(mouse.x, mouse.y)
          originY = point.y
          originHeight = panel.contentHeight
        }
        onPositionChanged: function(mouse) {
          if (!pressed) return
          var dy = mapToGlobal(mouse.x, mouse.y).y - originY
          if (panel.barPos === "bottom") dy = -dy
          var maxHeight = panel.availableCardHeight > 0 ? panel.availableCardHeight : Style.space(900)
          root.userPanelHeight = Math.max(Style.space(240), Math.min(maxHeight, originHeight + dy))
        }
        onReleased: if (root.userPanelHeight > 0) root.saveSetting("panelHeight", Math.round(root.userPanelHeight))

        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(4)
          width: Style.space(36)
          height: Style.space(3)
          radius: height / 2
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, parent.containsMouse ? 0.7 : 0.35)
        }
      }
    }
  }

  // Fullscreen transparent surface behind the card: any click outside the
  // card dismisses the panel while unpinned. Pinning simply unmaps it, so
  // the card window itself never changes size or position (avoids Hyprland
  // layer-resize animation flashes).
  PanelWindow {
    id: dismissWindow
    visible: root.opened && !root.pinned
    screen: panel.screen
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "omarchy-orca-status-dismiss"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors.left: true
    anchors.right: true
    anchors.top: true
    anchors.bottom: true

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
      onPressed: root.forceClose()
    }
  }

  PanelWindow {
    id: stickWindow
    visible: root.opened
    screen: panel.screen
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "omarchy-orca-status-pin"
    WlrLayershell.keyboardFocus: root.pinned ? WlrKeyboardFocus.None : WlrKeyboardFocus.OnDemand

    anchors.left: false
    anchors.bottom: false
    anchors.top: true
    anchors.right: true
    implicitWidth: Math.max(Style.space(320), panel.contentWidth)
    implicitHeight: Math.max(Style.space(240), panel.contentHeight)
    margins.top: (root.bar ? root.bar.barSize : Style.bar.sizeHorizontal) + Style.gapsOut
    margins.right: Style.gapsOut

    BorderSurface {
      id: stickCard
      anchors.fill: parent
      color: Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.popupPadding
      radius: Style.cornerRadius

      Item {
        id: stickHost
        anchors.fill: parent
        anchors.topMargin: stickCard.contentTopInset
        anchors.rightMargin: stickCard.contentRightInset
        anchors.bottomMargin: stickCard.contentBottomInset
        anchors.leftMargin: stickCard.contentLeftInset
      }
    }

    onVisibleChanged: root.placePanelBody()
  }

  component ProjectChip: Rectangle {
    id: projectChip
    property var project
    property color foreground
    property string fontFamily
    property bool selected: false
    property bool hovered: false
    signal clicked()

    readonly property color badge: project.badgeColor || "#525252"
    readonly property color ink: badge.hslLightness > 0.62 ? "#1a1a1a" : "#f4f4f5"
    readonly property string initials: Model.projectInitials(project.displayName)
    readonly property string fullName: project.displayName || "Project"

    implicitWidth: chipRow.implicitWidth + Style.space(16)
    implicitHeight: Style.space(28)
    radius: height / 2
    color: hovered ? Qt.lighter(badge, 1.15) : badge
    border.width: selected ? 2 : 0
    border.color: foreground

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: projectChip.hovered = containsMouse
      onClicked: projectChip.clicked()
    }

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        text: projectChip.initials
        color: projectChip.ink
        font.family: fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }

      Rectangle {
        width: Style.space(14)
        height: Style.space(14)
        radius: width / 2
        color: projectChip.ink
        anchors.verticalCenter: parent.verticalCenter

        Rectangle {
          anchors.centerIn: parent
          width: Style.space(8)
          height: Style.space(8)
          radius: width / 2
          color: Model.workspaceStatusColor(project.workspaceStatus)
        }
      }
    }

    PanelToolTip {
      visible: chipMouse.containsMouse
      text: projectChip.fullName + " · " + Model.workspaceStatusLabel(project.workspaceStatus)
      fontFamily: fontFamily
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
    property bool rowHover: false
    property bool focusHover: false
    property bool openHover: false
    property bool diffHover: false
    readonly property bool hovered: rowHover || focusHover || openHover || diffHover
    signal clicked()
    signal focusRequested()
    signal openRequested()
    signal diffRequested()
    signal agentClicked(var agent)

    radius: Style.cornerRadius
    color: selected || hovered
      ? Qt.rgba(foreground.r, foreground.g, foreground.b, 0.10)
      : Qt.rgba(foreground.r, foreground.g, foreground.b, 0.04)
    implicitHeight: content.implicitHeight + Style.space(12)

    Column {
      id: content
      z: 0
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: Style.space(8)
      spacing: Style.space(6)

      RowLayout {
        id: header
        width: parent.width
        spacing: Style.space(8)

        Rectangle {
          width: Style.space(8)
          height: Style.space(8)
          radius: width / 2
          color: Model.workspaceStatusColor(worktree.workspaceStatus)
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
          visible: !(worktreeRow.hovered || selected)
          text: Model.workspaceStatusLabel(worktree.workspaceStatus)
          color: Model.workspaceStatusColor(worktree.workspaceStatus)
          font.family: fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      UsageMeter {
        width: parent.width
        usage: worktreeRow.worktree.usage
        palette: worktreeRow.palette
        foreground: worktreeRow.foreground
        fontFamily: worktreeRow.fontFamily
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

                UsageMeter {
                  Layout.fillWidth: true
                  visible: modelData.usage && !Model.sameUsage(modelData.usage, worktreeRow.worktree.usage)
                  usage: modelData.usage
                  palette: worktreeRow.palette
                  foreground: worktreeRow.foreground
                  fontFamily: worktreeRow.fontFamily
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

            MouseArea {
              anchors.fill: parent
              z: 1
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: worktreeRow.agentClicked(modelData)
            }
          }
        }
      }
    }

    MouseArea {
      z: 1
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: header.implicitHeight + Style.space(16)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: worktreeRow.rowHover = containsMouse
      onClicked: worktreeRow.clicked()
    }

    Row {
      z: 2
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(8)
      visible: worktreeRow.hovered || selected
      spacing: Style.space(4)

      PanelActionButton {
        iconText: "󰆍"
        tooltipText: "Focus in Orca (f)"
        foreground: worktreeRow.foreground
        fontFamily: worktreeRow.fontFamily
        onClicked: worktreeRow.focusRequested()
        onHovered: function(isHovered) { worktreeRow.focusHover = isHovered }
      }

      PanelActionButton {
        iconText: "󰦓"
        tooltipText: "Open changed files (d)"
        foreground: worktreeRow.foreground
        fontFamily: worktreeRow.fontFamily
        onClicked: worktreeRow.diffRequested()
        onHovered: function(isHovered) { worktreeRow.diffHover = isHovered }
      }

      PanelActionButton {
        iconText: "󰷏"
        tooltipText: "Open path (o)"
        foreground: worktreeRow.foreground
        fontFamily: worktreeRow.fontFamily
        onClicked: worktreeRow.openRequested()
        onHovered: function(isHovered) { worktreeRow.openHover = isHovered }
      }
    }
  }

  component UsageMeter: RowLayout {
    property var usage
    property var palette
    property color foreground
    property string fontFamily
    visible: usage && usage.label
    spacing: Style.space(8)

    Rectangle {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      implicitHeight: Style.space(3)
      radius: height / 2
      color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.14)

      Rectangle {
        width: parent.width * Math.max(0, Math.min(1, Number(usage && usage.percent) / 100))
        height: parent.height
        radius: height / 2
        color: Model.usageColor(usage ? usage.percent : 0, palette)
      }
    }

    Text {
      textFormat: Text.PlainText
      text: usage && usage.label ? usage.label : ""
      color: Model.usageColor(usage ? usage.percent : 0, palette)
      font.family: fontFamily
      font.pixelSize: Style.font.caption
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
