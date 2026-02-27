const STORAGE_PREFIX = "algedonia:"
const DEFAULT_MODE = "expanded"

const parseWidth = (value) => {
  const parsed = Number.parseInt(value, 10)
  return Number.isFinite(parsed) ? parsed : null
}

const clamp = (value, min, max) => Math.max(min, Math.min(max, value))

const SplitPanel = {
  mounted() {
    const minWidth = parseWidth(this.el.dataset.minWidth) ?? 320
    const maxWidth = parseWidth(this.el.dataset.maxWidth) ?? 640
    const defaultWidth = parseWidth(this.el.dataset.defaultWidth) ?? 384
    const storageKey = this.el.dataset.storageKey
      ? `${STORAGE_PREFIX}${this.el.dataset.storageKey}`
      : null

    this.dimensions = { minWidth, maxWidth, defaultWidth, storageKey }

    this.onPointerDown = (event) => {
      event.preventDefault()
      this.handle?.setPointerCapture(event.pointerId)
      this.applyLayout(DEFAULT_MODE)

      this.onPointerMove = (moveEvent) => {
        this.applyWidth(this.widthFromPointer(moveEvent.clientX))
      }

      this.onPointerUp = () => {
        this.persistWidth()
        this.cleanupPointerTracking()
      }

      window.addEventListener("pointermove", this.onPointerMove)
      window.addEventListener("pointerup", this.onPointerUp)
      window.addEventListener("pointercancel", this.onPointerUp)
    }

    this.onKeyDown = (event) => {
      const key = event.key
      if (key !== "ArrowLeft" && key !== "ArrowRight") return

      event.preventDefault()
      const currentWidth = this.currentWidth()
      const delta = event.shiftKey ? 32 : 16
      const nextWidth =
        key === "ArrowLeft" ? currentWidth + delta : currentWidth - delta

      this.applyWidth(nextWidth)
      this.persistWidth()
    }

    this.onAction = (event) => {
      const action = event.detail?.action
      if (!action) return

      if (action === "collapse-right") {
        this.applyLayout(this.mode === "right-collapsed" ? DEFAULT_MODE : "right-collapsed")
      } else {
        return
      }

      this.persistWidth()
    }

    this.refreshElements()
    this.bindEvents()
    const { width, mode } = this.restoreState()
    this.applyWidth(width)
    this.applyLayout(mode)
  },

  updated() {
    this.refreshElements()
    this.bindEvents()

    const { width, mode } = this.restoreState()
    const nextWidth = this.width ?? width
    const nextMode = this.mode ?? mode

    this.applyWidth(nextWidth)
    this.applyLayout(nextMode)
  },

  destroyed() {
    this.cleanupPointerTracking()

    if (this.boundHandle) {
      this.boundHandle.removeEventListener("pointerdown", this.onPointerDown)
      this.boundHandle.removeEventListener("keydown", this.onKeyDown)
    }

    if (this.actionBound) {
      window.removeEventListener("split-panel:action", this.onAction)
      this.actionBound = false
    }
  },

  refreshElements() {
    this.handle = this.el.querySelector("[data-split-handle]")
    this.leftPanel = this.el.querySelector("[data-split-left]")
    this.rightPanel = this.el.querySelector("[data-split-right]")
  },

  bindEvents() {
    if (!this.handle) return

    if (this.boundHandle && this.boundHandle !== this.handle) {
      this.boundHandle.removeEventListener("pointerdown", this.onPointerDown)
      this.boundHandle.removeEventListener("keydown", this.onKeyDown)
    }

    if (this.boundHandle !== this.handle) {
      this.handle.addEventListener("pointerdown", this.onPointerDown)
      this.handle.addEventListener("keydown", this.onKeyDown)
      this.boundHandle = this.handle
    }

    this.handle.setAttribute("aria-valuemin", String(this.dimensions.minWidth))
    this.handle.setAttribute("aria-valuemax", String(this.dimensions.maxWidth))

    if (!this.actionBound) {
      window.addEventListener("split-panel:action", this.onAction)
      this.actionBound = true
    }
  },

  widthFromPointer(pointerX) {
    const bounds = this.el.getBoundingClientRect()
    const width = bounds.right - pointerX
    return clamp(width, this.dimensions.minWidth, this.dimensions.maxWidth)
  },

  currentWidth() {
    const inlineValue = this.el.style.getPropertyValue("--inspector-width")
    const parsed = parseWidth(inlineValue)
    return parsed ?? this.dimensions.defaultWidth
  },

  applyWidth(width) {
    const clamped = clamp(width, this.dimensions.minWidth, this.dimensions.maxWidth)
    this.width = clamped
    this.el.style.setProperty("--inspector-width", `${clamped}px`)
    this.handle?.setAttribute("aria-valuenow", String(clamped))

    if (this.mode) {
      this.applyLayout(this.mode)
    }
  },

  applyLayout(mode) {
    this.mode = mode

    if (mode === "right-collapsed") {
      this.leftPanel?.classList.remove("hidden")
      this.rightPanel?.classList.add("hidden")
      this.el.style.gridTemplateColumns = "minmax(0,1fr) 10px 0px"
      return
    }

    this.leftPanel?.classList.remove("hidden")
    this.rightPanel?.classList.remove("hidden")
    this.el.style.gridTemplateColumns = `minmax(0,1fr) 10px ${this.currentWidth()}px`
  },

  persistWidth() {
    const key = this.dimensions.storageKey
    if (!key) return

    try {
      const state = JSON.stringify({
        width: this.currentWidth(),
        mode: this.mode || DEFAULT_MODE
      })
      window.localStorage.setItem(key, state)
    } catch (_error) {}
  },

  restoreState() {
    const key = this.dimensions.storageKey
    if (!key) {
      return {
        width: this.dimensions.defaultWidth,
        mode: DEFAULT_MODE
      }
    }

    try {
      const raw = window.localStorage.getItem(key)
      if (!raw) {
        return {
          width: this.dimensions.defaultWidth,
          mode: DEFAULT_MODE
        }
      }

      // Support old storage format where only width was saved.
      const legacyWidth = parseWidth(raw)
      if (legacyWidth !== null) {
        return {
          width: legacyWidth,
          mode: DEFAULT_MODE
        }
      }

      const parsed = JSON.parse(raw)
      const restoredWidth = parseWidth(parsed?.width) ?? this.dimensions.defaultWidth
      const restoredMode =
        parsed?.mode === "right-collapsed"
          ? parsed.mode
          : DEFAULT_MODE

      return {
        width: restoredWidth,
        mode: restoredMode
      }
    } catch (_error) {}

    return {
      width: this.dimensions.defaultWidth,
      mode: DEFAULT_MODE
    }
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

export default SplitPanel
