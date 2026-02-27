/**
 * KeyboardShortcuts — centralized keyboard shortcut handler.
 *
 * Reads the current page context from `data-page` on the hook element and
 * dispatches shortcuts accordingly. Skips when focus is inside editable
 * elements (inputs, textareas, selects, contentEditable).
 *
 * The hook element should carry `data-page="tickets"` or `data-page="loop"`.
 */
const KeyboardShortcuts = {
  mounted() {
    this.onKeyDown = (event) => {
      if (this.isEditable(event.target)) return

      const rawKey = event.key
      const key = rawKey.length === 1 ? rawKey.toLowerCase() : rawKey
      const meta = event.metaKey || event.ctrlKey
      const page = this.el.dataset.page

      // Global: ? — toggle shortcut help
      if (key === "?" && !meta) {
        event.preventDefault()
        this.pushEvent("toggle_shortcut_help", {})
        return
      }

      if (page === "tickets") {
        this.handleTicketShortcuts(event, key, meta)
      } else if (page === "loop") {
        this.handleLoopShortcuts(event, key, meta)
      }
    }

    window.addEventListener("keydown", this.onKeyDown)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeyDown)
  },

  isEditable(target) {
    if (!target) return false
    const node = target.nodeType === Node.TEXT_NODE ? target.parentElement : target
    if (!(node instanceof Element)) return false

    if (node.closest("[data-shortcuts='off']")) return true
    if (node.closest(".tiptap, .ProseMirror")) return true
    if (node.isContentEditable) return true
    if (node.closest("[contenteditable=''], [contenteditable='true'], [contenteditable='plaintext-only']")) return true

    const tag = node.tagName?.toLowerCase()
    return tag === "input" || tag === "textarea" || tag === "select"
  },

  handleTicketShortcuts(event, key, meta) {
    // ⌘/⌃ + B or just B — toggle board/list view
    if ((meta && key === "b") || (!meta && key === "b")) {
      event.preventDefault()
      this.pushEvent("toggle_view_shortcut", {})
      return
    }

    // Escape — back to list (from detail view)
    if (key === "Escape") {
      this.pushEvent("shortcut_back", {})
      return
    }
  },

  handleLoopShortcuts(event, key, meta) {
    if (event.ctrlKey && key === "`") {
      event.preventDefault()
      window.dispatchEvent(new CustomEvent("split-panel:action", { detail: { action: "collapse-right" } }))
      return
    }

    if (meta) return

    // S — start/stop loop
    if (key === "s") {
      event.preventDefault()
      this.pushEvent("shortcut_toggle_loop", {})
      return
    }

    // 1/2 — switch sidebar tabs
    if (key === "1") {
      event.preventDefault()
      this.pushEvent("switch_tab", { tab: "overview" })
      return
    }
    if (key === "2") {
      event.preventDefault()
      this.pushEvent("switch_tab", { tab: "rubric" })
      return
    }
    if (key === "3") {
      event.preventDefault()
      this.pushEvent("toggle_steps", {})
      return
    }

    // Escape — back to tickets
    if (key === "Escape") {
      this.pushEvent("shortcut_back", {})
      return
    }
  }
}

export default KeyboardShortcuts
