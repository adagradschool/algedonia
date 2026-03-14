let hljs = null

async function loadHighlightJS() {
  if (hljs) return hljs

  const mod = await import("highlight.js/lib/core")
  hljs = mod.default

  const bash = await import("highlight.js/lib/languages/bash")
  hljs.registerLanguage("bash", bash.default)

  return hljs
}

const DRAG_ACTIVE_CLASS = "script-editor-shell--drag-active"
const MULTI_FILE_ERROR = "Drop exactly one text file."
const READ_ERROR = "Could not read dropped file as text."

function dispatchFormEvents(textarea) {
  textarea.dispatchEvent(new Event("input", {bubbles: true}))
  textarea.dispatchEvent(new Event("change", {bubbles: true}))
}

function hasBinaryNullByte(text) {
  return text.includes("\u0000")
}

function isLikelyTextFile(file) {
  const type = (file.type || "").toLowerCase()
  return (
    type === "" ||
    type.startsWith("text/") ||
    type === "application/x-sh" ||
    type === "application/x-shellscript"
  )
}

const ScriptEditor = {
  async mounted() {
    this.textarea = this.el.querySelector("[data-role='source']")
    this.code = this.el.querySelector("[data-role='highlight']")
    this.shell = this.el.querySelector(".script-editor-shell")
    this.errorEl = this.el.querySelector("[data-role='drop-error']")
    this.hl = null
    this.field = this.el.dataset.scriptField || null
    this.lastErrorMessage = null

    if (!this.textarea || !this.code || !this.shell) return

    this.onInput = () => {
      this.syncHighlight()
      this.clearError()
    }

    this.onScroll = () => {
      this.code.parentElement.scrollTop = this.textarea.scrollTop
      this.code.parentElement.scrollLeft = this.textarea.scrollLeft
    }

    this.onDragOver = (event) => {
      event.preventDefault()
      this.shell.classList.add(DRAG_ACTIVE_CLASS)
    }

    this.onDragLeave = (event) => {
      if (event.currentTarget === event.target) {
        this.shell.classList.remove(DRAG_ACTIVE_CLASS)
      }
    }

    this.onDrop = async (event) => {
      event.preventDefault()
      this.shell.classList.remove(DRAG_ACTIVE_CLASS)

      const files = Array.from(event.dataTransfer?.files || [])
      if (files.length !== 1) {
        this.showError(MULTI_FILE_ERROR)
        return
      }

      try {
        const [file] = files
        if (!isLikelyTextFile(file)) throw new Error("non-text file")

        const content = await file.text()
        if (hasBinaryNullByte(content)) throw new Error("binary file")

        this.textarea.value = content
        this.syncHighlight()
        this.clearError()
        dispatchFormEvents(this.textarea)
      } catch (_error) {
        this.showError(READ_ERROR)
      }
    }

    this.textarea.addEventListener("input", this.onInput)
    this.textarea.addEventListener("scroll", this.onScroll)
    this.shell.addEventListener("dragover", this.onDragOver)
    this.shell.addEventListener("dragleave", this.onDragLeave)
    this.shell.addEventListener("drop", this.onDrop)

    this.hl = await loadHighlightJS()
    this.syncHighlight()
  },

  updated() {
    this.syncHighlight()
  },

  destroyed() {
    if (!this.textarea || !this.shell) return

    this.textarea.removeEventListener("input", this.onInput)
    this.textarea.removeEventListener("scroll", this.onScroll)
    this.shell.removeEventListener("dragover", this.onDragOver)
    this.shell.removeEventListener("dragleave", this.onDragLeave)
    this.shell.removeEventListener("drop", this.onDrop)
  },

  syncHighlight() {
    if (!this.code || !this.textarea) return

    const value = this.textarea.value || ""
    if (this.hl) {
      this.code.innerHTML = this.hl.highlight(value, {language: "bash"}).value
    } else {
      this.code.textContent = value
    }
  },

  showError(message) {
    if (!this.errorEl) return
    this.errorEl.textContent = message
    this.errorEl.classList.remove("hidden")
    this.reportError(message)
  },

  clearError() {
    if (!this.errorEl) return
    this.errorEl.textContent = ""
    this.errorEl.classList.add("hidden")
    this.reportError(null)
  },

  reportError(message) {
    if (!this.field || this.lastErrorMessage === message) return
    this.lastErrorMessage = message
    this.pushEvent("script_drop_error", {field: this.field, message})
  }
}

export default ScriptEditor
