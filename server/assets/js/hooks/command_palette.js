const CommandPalette = {
  mounted() {
    this.isOpen = false
    this.activeIndex = 0
    this.items = this.buildItems()
    this.render()

    this.onKeyDown = (event) => {
      const key = event.key
      const meta = event.metaKey || event.ctrlKey

      if (meta && key.toLowerCase() === "k") {
        event.preventDefault()
        this.toggle()
        return
      }

      if (!this.isOpen) return

      if (key === "Escape") {
        event.preventDefault()
        this.close()
        return
      }

      if (key === "ArrowDown") {
        event.preventDefault()
        this.activeIndex = (this.activeIndex + 1) % this.items.length
        this.render()
        return
      }

      if (key === "ArrowUp") {
        event.preventDefault()
        this.activeIndex = (this.activeIndex - 1 + this.items.length) % this.items.length
        this.render()
        return
      }

      if (key === "Enter") {
        event.preventDefault()
        this.navigate(this.items[this.activeIndex])
      }
    }

    window.addEventListener("keydown", this.onKeyDown)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeyDown)
    this.teardown()
  },

  buildItems() {
    const items = []
    const ticketsPath = this.el.dataset.ticketsPath
    const monitorPath = this.el.dataset.monitorPath
    const newIssuePath = this.el.dataset.newIssuePath
    const loopPath = this.el.dataset.loopPath

    if (ticketsPath) items.push({label: "Issues", hint: "G I", path: ticketsPath})
    if (monitorPath) items.push({label: "Monitor", hint: "G M", path: monitorPath})
    if (newIssuePath) items.push({label: "New Issue", hint: "Cmd K", path: newIssuePath})
    if (loopPath) items.push({label: "Loop Inspector", hint: "G L", path: loopPath})

    return items
  },

  toggle() {
    if (this.isOpen) {
      this.close()
    } else {
      this.open()
    }
  },

  open() {
    this.isOpen = true
    this.activeIndex = 0
    this.render()
  },

  close() {
    this.isOpen = false
    this.render()
  },

  navigate(item) {
    if (!item) return
    window.location.assign(item.path)
  },

  teardown() {
    const overlay = this.el.querySelector("[data-command-overlay]")
    if (overlay) overlay.remove()
  },

  render() {
    this.teardown()
    if (!this.isOpen || this.items.length === 0) return

    const overlay = document.createElement("div")
    overlay.setAttribute("data-command-overlay", "true")
    overlay.className = "command-palette-overlay"
    overlay.innerHTML = `
      <div class="command-palette-panel" role="dialog" aria-modal="true" aria-label="Command palette">
        <div class="command-palette-head">Jump to</div>
        <div class="command-palette-list">
          ${this.items
            .map((item, index) => {
              const activeClass = index === this.activeIndex ? "command-palette-item active" : "command-palette-item"
              return `<button type="button" data-cmd-index="${index}" class="${activeClass}">
                <span>${item.label}</span>
                <kbd>${item.hint}</kbd>
              </button>`
            })
            .join("")}
        </div>
      </div>
    `

    overlay.addEventListener("click", (event) => {
      if (event.target === overlay) this.close()
    })

    overlay.querySelectorAll("[data-cmd-index]").forEach((button) => {
      button.addEventListener("click", () => {
        const index = Number.parseInt(button.dataset.cmdIndex || "0", 10)
        this.navigate(this.items[index])
      })
    })

    this.el.appendChild(overlay)
  }
}

export default CommandPalette
