import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import "@xterm/xterm/css/xterm.css"

const XTerm = {
  mounted() {
    this.term = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: "'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace",
      theme: {
        background: "#1a1b26",
        foreground: "#a9b1d6",
        cursor: "#c0caf5",
        selectionBackground: "#33467c"
      },
      convertEol: true,
      scrollback: 10000,
    })

    this.fitAddon = new FitAddon()
    this.term.loadAddon(this.fitAddon)
    this.term.open(this.el)
    this.fitAddon.fit()

    this.term.onData((data) => {
      this.pushEvent("terminal_input", { data: btoa(data) })
    })

    this.resizeObserver = new ResizeObserver(() => {
      this.fitAddon.fit()
    })
    this.resizeObserver.observe(this.el)

    this.handleEvent("terminal_data", ({ data }) => {
      const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0))
      this.term.write(bytes)
    })

    this.handleEvent("terminal_scrollback", ({ data }) => {
      const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0))
      this.term.write(bytes)
    })

    this.handleEvent("terminal_ended", ({ exit_code }) => {
      this.term.write(`\r\n\x1b[1;33m--- Process exited with code ${exit_code} ---\x1b[0m\r\n`)
    })
  },

  destroyed() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
    }
    if (this.term) {
      this.term.dispose()
    }
  }
}

export default XTerm
