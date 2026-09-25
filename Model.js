.pragma library

function parseResult(text) {
  try {
    var result = JSON.parse(String(text || "{}"))
    if (!result || typeof result !== "object") return { ok: false, error: "Unreadable response." }
    return result
  } catch (e) {
    return { ok: false, error: "Unable to read Orca status." }
  }
}

function matches(row, query) {
  var q = String(query || "").toLowerCase().replace(/^\s+|\s+$/g, "")
  if (q === "") return true
  var haystack = [
    row.repo, row.displayName, row.path, row.branch, row.summary, row.preview, row.state
  ].join(" ").toLowerCase()
  var terms = q.split(/\s+/)
  for (var i = 0; i < terms.length; i++) {
    if (haystack.indexOf(terms[i]) < 0) return false
  }
  return true
}

function worktreeHasPresence(row) {
  if (!row) return false
  if (row.agents && row.agents.length > 0) return true
  if (row.liveTerminalCount > 0) return true
  if (row.state === "working" || row.state === "waiting" || row.state === "blocked") return true
  return false
}

function filteredWorktrees(worktrees, query) {
  var out = []
  for (var i = 0; i < worktrees.length; i++) {
    if (!worktreeHasPresence(worktrees[i])) continue
    if (matches(worktrees[i], query)) out.push(worktrees[i])
  }
  return out
}

function workspaceStatusColor(status) {
  switch (String(status || "").toLowerCase()) {
    case "in-progress": return "#eab308"
    case "in-review": return "#22c55e"
    case "completed":
    case "done": return "#e7b89a"
    case "todo": return "#a1a1aa"
    default: return "#a1a1aa"
  }
}

function projectInitials(name) {
  var text = String(name || "").replace(/^\s+|\s+$/g, "")
  if (text === "") return "?"
  var words = text.split(/[\s._/-]+/)
  var parts = []
  for (var i = 0; i < words.length; i++) {
    if (words[i] !== "") parts.push(words[i])
  }
  if (parts.length >= 2) return (parts[0].charAt(0) + parts[1].charAt(0)).toUpperCase()
  var word = parts.length > 0 ? parts[0] : text
  return word.substring(0, 2).toUpperCase()
}

function workspaceStatusLabel(status) {
  switch (String(status || "").toLowerCase()) {
    case "in-progress": return "In progress"
    case "in-review": return "In review"
    case "completed":
    case "done": return "Done"
    case "todo": return "Todo"
    default: return "Todo"
  }
}

function usageColor(percent, palette) {
  var colors = palette || {}
  var value = Number(percent)
  if (value >= 95) return colors.urgent || "#f38ba8"
  if (value >= 80) return colors.warning || "#fab387"
  return colors.success || "#a6e3a1"
}

function sameUsage(left, right) {
  if (!left || !right) return false
  return String(left.model || "") === String(right.model || "")
    && Math.round(Number(left.percent)) === Math.round(Number(right.percent))
}

function stateColor(state, palette) {
  var colors = palette || {}
  switch (String(state || "").toLowerCase()) {
    case "blocked": return colors.urgent || "#f38ba8"
    case "waiting": return colors.warning || "#fab387"
    case "working": return colors.success || "#a6e3a1"
    case "done": return colors.dim || "#6c7086"
    default: return colors.dim || "#6c7086"
  }
}

function stateLabel(state) {
  switch (String(state || "").toLowerCase()) {
    case "blocked": return "Blocked"
    case "waiting": return "Waiting"
    case "working": return "Working"
    case "done": return "Done"
    default: return "Inactive"
  }
}

function agentGlyph(agentType, displayLabel) {
  var key = String(displayLabel || agentType || "").toLowerCase()
  if (key.indexOf("cursor") >= 0) return "󰆍"
  switch (key) {
    case "codex": return "󰚩"
    case "claude":
    case "claude-code": return "󰭹"
    case "omp": return "󰚩"
    case "hermes": return "󰚩"
    default: return "󰆍"
  }
}

function agentLabel(agent) {
  if (!agent) return "agent"
  if (agent.displayLabel) return agent.displayLabel
  if (agent.displayName) return agent.displayName
  return agent.agentType || "agent"
}

function headline(data) {
  if (!data || data.offline) return "Orca offline"
  if (data.headline) return "Orca — " + data.headline
  return "Orca"
}

function barTooltip(data) {
  if (!data) return "Orca Status"
  if (data.offline) return "Orca offline"
  var parts = []
  if (data.summary) {
    if (data.summary.blocked > 0) parts.push(data.summary.blocked + " blocked")
    if (data.summary.waiting > 0) parts.push(data.summary.waiting + " waiting")
    if (data.summary.working > 0) parts.push(data.summary.working + " working")
  }
  if (parts.length === 0) return "Orca — idle"
  return "Orca — " + parts.join(", ")
}

function shouldShowBar(data, showWhenIdle) {
  if (!data || !data.loaded) return false
  if (data.offline) return true
  if (showWhenIdle) return true
  if (!data.summary) return false
  if (data.summary.blocked > 0 || data.summary.waiting > 0 || data.summary.working > 0) return true
  if (data.worktrees && data.worktrees.length > 0) {
    for (var i = 0; i < data.worktrees.length; i++) {
      var wt = data.worktrees[i]
      if (wt.liveTerminalCount > 0 || wt.state === "working" || wt.state === "waiting" || wt.state === "blocked") return true
    }
  }
  return false
}

function semaphoreColor(semaphore, palette) {
  switch (String(semaphore || "").toLowerCase()) {
    case "red": return palette.urgent
    case "yellow": return palette.warning
    case "green": return palette.success
    default: return palette.dim
  }
}

function worktreesForProject(project, worktrees) {
  var out = []
  for (var i = 0; i < worktrees.length; i++) {
    var wt = worktrees[i]
    if (project.displayName && wt.repo === project.displayName) out.push(wt)
  }
  return out
}

function rowTitle(worktree) {
  if (worktree.displayName && worktree.branch && worktree.displayName !== worktree.branch)
    return worktree.displayName + " · " + worktree.branch
  return worktree.displayName || worktree.repo || worktree.path || "Workspace"
}

function rowMeta(worktree) {
  var parts = []
  if (worktree.repo) parts.push(worktree.repo)
  if (worktree.liveTerminalCount > 0) parts.push(worktree.liveTerminalCount + " live")
  if (worktree.agents && worktree.agents.length > 0) parts.push(worktree.agents.length + " agent" + (worktree.agents.length === 1 ? "" : "s"))
  return parts.join("  ·  ")
}

function switchResultText(result) {
  if (!result || !result.ok) return result && result.error ? result.error : "Unable to focus workspace."
  return "Focused in Orca."
}

function hasActiveWorktrees(worktrees) {
  for (var i = 0; i < worktrees.length; i++) {
    var wt = worktrees[i]
    if (!wt) continue
    if (wt.state === "working" || wt.state === "waiting" || wt.state === "blocked") return true
    if (wt.liveTerminalCount > 0) return true
  }
  return false
}

function primaryAgentLabel(worktrees) {
  for (var i = 0; i < worktrees.length; i++) {
    var agents = worktrees[i].agents || []
    for (var j = 0; j < agents.length; j++) {
      if (agents[j].displayLabel) return agents[j].displayLabel
      if (agents[j].agentType) return agents[j].agentType
    }
  }
  return ""
}

function barIconForWorktrees(worktrees) {
  return agentGlyph("", primaryAgentLabel(worktrees))
}
