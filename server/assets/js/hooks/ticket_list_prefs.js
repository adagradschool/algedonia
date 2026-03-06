const STORAGE_PREFIX = "algedonia:ticket-list-prefs:"

const TicketListPrefs = {
  mounted() {
    const slug = this.el.dataset.workspaceSlug
    if (!slug) return

    this.storageKey = `${STORAGE_PREFIX}${slug}`

    const prefs = this.restorePrefs()
    if (prefs) {
      this.pushEvent("restore_prefs", prefs)
    }

    this.handleEvent("persist_prefs", (payload) => {
      this.persistPrefs(payload)
    })
  },

  persistPrefs(payload) {
    if (!this.storageKey) return

    try {
      window.localStorage.setItem(this.storageKey, JSON.stringify(payload))
    } catch (_error) {}
  },

  restorePrefs() {
    if (!this.storageKey) return null

    try {
      const raw = window.localStorage.getItem(this.storageKey)
      if (!raw) return null

      const parsed = JSON.parse(raw)
      if (!parsed || typeof parsed !== "object") return null

      const result = {}
      if (typeof parsed.sort_by === "string") result.sort_by = parsed.sort_by
      if (typeof parsed.view_mode === "string") result.view_mode = parsed.view_mode
      if (Object.keys(result).length === 0) return null

      return result
    } catch (_error) {
      return null
    }
  }
}

export default TicketListPrefs
