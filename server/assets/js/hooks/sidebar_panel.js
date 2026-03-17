const STORAGE_PREFIX = "algedonia:"
const LEGACY_STORAGE_KEYS = ["workspace-left-sidebar-width", "loop-left-sidebar-width"]

const parseStoredState = (raw) => {
  if (!raw) return null

  const legacyWidth = parseWidth(raw)
  if (legacyWidth !== null) {
    return {
      width: legacyWidth,
      collapsed: false
    }
  }

  try {
    const parsed = JSON.parse(raw)
    return {
      width: parseWidth(parsed?.width),
      collapsed: parsed?.collapsed === true
    }
  } catch (_error) {
    return null
  }
}

const parseWidth = (value) => {
  const parsed = Number.parseInt(value, 10)
  return Number.isFinite(parsed) ? parsed : null
}

const clamp = (value, min, max) => Math.max(min, Math.min(max, value))

const SidebarPanel = {
  mounted() {
    const minWidth = parseWidth(this.el.dataset.minWidth) ?? 208
    const maxWidth = parseWidth(this.el.dataset.maxWidth) ?? 448
    const defaultWidth = parseWidth(this.el.dataset.defaultWidth) ?? 256
    const collapsedWidth = parseWidth(this.el.dataset.collapsedWidth) ?? 52
    const handleWidth = parseWidth(this.el.dataset.handleWidth) ?? 10
    const storageKey = this.el.dataset.storageKey
      ? `${STORAGE_PREFIX}${this.el.dataset.storageKey}`
      : null

    this.dimensions = { minWidth, maxWidth, defaultWidth, collapsedWidth, handleWidth, storageKey }

    this.onPointerDown = (event) => {
      if (this.collapsed) return

      event.preventDefault()
      this.handle?.setPointerCapture(event.pointerId)

      this.onPointerMove = (moveEvent) => {
        this.applyWidth(this.widthFromPointer(moveEvent.clientX))
      }

      this.onPointerUp = () => {
        this.persistState()
        this.cleanupPointerTracking()
      }

      window.addEventListener("pointermove", this.onPointerMove)
      window.addEventListener("pointerup", this.onPointerUp)
      window.addEventListener("pointercancel", this.onPointerUp)
    }

    this.onToggle = (event) => {
      event.preventDefault()
      this.applyCollapsed(!this.collapsed)
      this.persistState()
    }

    this.refreshElements()
    this.bindEvents()

    const { width, collapsed } = this.restoreState()
    this.collapsed = collapsed
    this.applyWidth(width)
    this.applyCollapsed(this.collapsed)
  },

  updated() {
    this.refreshElements()
    this.bindEvents()

    const { width, collapsed } = this.restoreState()
    this.applyWidth(this.width ?? width)
    this.applyCollapsed(this.collapsed ?? collapsed)
  },

  destroyed() {
    this.cleanupPointerTracking()

    if (this.boundHandle) {
      this.boundHandle.removeEventListener("pointerdown", this.onPointerDown)
    }

    if (this.boundToggle) {
      this.boundToggle.removeEventListener("click", this.onToggle)
    }
  },

  refreshElements() {
    this.sidebar = this.el.querySelector("[data-sidebar-panel]")
    this.handle = this.el.querySelector("[data-sidebar-handle]")
    this.toggle = this.el.querySelector("[data-sidebar-toggle]")
  },

  bindEvents() {
    if (this.boundHandle && this.boundHandle !== this.handle) {
      this.boundHandle.removeEventListener("pointerdown", this.onPointerDown)
    }

    if (this.handle && this.boundHandle !== this.handle) {
      this.handle.addEventListener("pointerdown", this.onPointerDown)
      this.boundHandle = this.handle
    }

    if (this.boundToggle && this.boundToggle !== this.toggle) {
      this.boundToggle.removeEventListener("click", this.onToggle)
    }

    if (this.toggle && this.boundToggle !== this.toggle) {
      this.toggle.addEventListener("click", this.onToggle)
      this.boundToggle = this.toggle
    }
  },

  widthFromPointer(pointerX) {
    const bounds = this.el.getBoundingClientRect()
    const width = pointerX - bounds.left
    return clamp(width, this.dimensions.minWidth, this.dimensions.maxWidth)
  },

  currentWidth() {
    const inlineValue = this.el.style.getPropertyValue("--left-sidebar-width")
    const parsed = parseWidth(inlineValue)
    return parsed ?? this.dimensions.defaultWidth
  },

  applyWidth(width) {
    const clamped = clamp(width, this.dimensions.minWidth, this.dimensions.maxWidth)
    this.width = clamped
    this.el.style.setProperty("--left-sidebar-width", `${clamped}px`)
  },

  applyCollapsed(collapsed) {
    if (!this.sidebar || !this.toggle) return

    this.collapsed = collapsed

    if (collapsed) {
      this.el.classList.add("sidebar-panel-collapsed")
      this.el.style.gridTemplateColumns = `${this.dimensions.collapsedWidth}px ${this.dimensions.handleWidth}px minmax(0,1fr)`
      this.toggle.setAttribute("aria-label", "Expand sidebar")
      this.toggle.setAttribute("title", "Expand sidebar")
      this.toggle.setAttribute("aria-expanded", "false")
      this.toggle.dataset.state = "collapsed"
      return
    }

    this.el.classList.remove("sidebar-panel-collapsed")
    this.el.style.gridTemplateColumns = `${this.currentWidth()}px ${this.dimensions.handleWidth}px minmax(0,1fr)`
    this.toggle.setAttribute("aria-label", "Collapse sidebar")
    this.toggle.setAttribute("title", "Collapse sidebar")
    this.toggle.setAttribute("aria-expanded", "true")
    this.toggle.dataset.state = "expanded"
  },

  persistState() {
    const key = this.dimensions.storageKey
    if (!key) return

    try {
      const state = JSON.stringify({
        width: this.currentWidth(),
        collapsed: this.collapsed
      })
      window.localStorage.setItem(key, state)
    } catch (_error) {}
  },

  restoreState() {
    const fallback = {
      width: this.dimensions.defaultWidth,
      collapsed: false
    }

    const keys = this.dimensions.storageKey
      ? [
          this.dimensions.storageKey,
          ...LEGACY_STORAGE_KEYS
            .map((legacyKey) => `${STORAGE_PREFIX}${legacyKey}`)
            .filter((legacyKey) => legacyKey !== this.dimensions.storageKey)
        ]
      : []

    if (keys.length === 0) return fallback

    try {
      for (const key of keys) {
        const parsed = parseStoredState(window.localStorage.getItem(key))
        if (!parsed) continue

        const restored = {
          width: parsed.width ?? fallback.width,
          collapsed: parsed.collapsed
        }

        if (key !== this.dimensions.storageKey) {
          window.localStorage.setItem(this.dimensions.storageKey, JSON.stringify(restored))
        }

        return restored
      }
    } catch (_error) {
      return fallback
    }

    return fallback
  },

  cleanupPointerTracking() {
    if (this.onPointerMove) {
      window.removeEventListener("pointermove", this.onPointerMove)
    }
    if (this.onPointerUp) {
      window.removeEventListener("pointerup", this.onPointerUp)
      window.removeEventListener("pointercancel", this.onPointerUp)
    }
  }
}

export default SidebarPanel
