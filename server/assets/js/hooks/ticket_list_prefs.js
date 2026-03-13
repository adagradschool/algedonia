import {
  parseStoredPrefs,
  sanitizePersistedPrefs,
  storageKeyForWorkspace
} from "./ticket_list_prefs_storage.mjs"

const TicketListPrefs = {
  mounted() {
    const slug = this.el.dataset.workspaceSlug
    if (!slug) return

    this.storageKey = storageKeyForWorkspace(slug)

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
      const sanitized = sanitizePersistedPrefs(payload)
      if (!sanitized) return

      window.localStorage.setItem(this.storageKey, JSON.stringify(sanitized))
    } catch (_error) {}
  },

  restorePrefs() {
    if (!this.storageKey) return null

    try {
      return parseStoredPrefs(window.localStorage.getItem(this.storageKey))
    } catch (_error) {
      return null
    }
  }
}

export default TicketListPrefs
