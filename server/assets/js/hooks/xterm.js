import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import "@xterm/xterm/css/xterm.css"

const FIT_DEBOUNCE_MS = 60
const MIN_RENDERABLE_WIDTH_PX = 24
const MIN_RENDERABLE_HEIGHT_PX = 24

function ensureTerminalMetricsStore() {
  if (!window.__algedoniaTerminalMetrics) {
    window.__algedoniaTerminalMetrics = {}
  }
  return window.__algedoniaTerminalMetrics
}

const XTerm = {
  mounted() {
    this.metrics = {
      writeErrors: 0,
      decodeErrors: 0,
      queueFlushes: 0,
      queuedBytes: 0,
      fitSkips: 0,
      fitErrors: 0,
      parserHardeningEnabled: false,
    }
    ensureTerminalMetricsStore()[this.el.id] = this.metrics

    this.writeQueue = []
    this.queuedBytes = 0
    this.writeFrame = null
    this.fitDebounceTimer = null
    this.fitFrame = null
    this.parserDisposables = []

    this.term = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: "'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace",
      allowProposedApi: true,
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
    this.setupParserHardening()
    this.scheduleFit()

    this.term.onData((data) => {
      this.pushEvent("terminal_input", { data: btoa(data) })
    })

    this.resizeObserver = new ResizeObserver(() => {
      this.scheduleFit()
    })
    this.resizeObserver.observe(this.el)

    this.handleEvent("terminal_data", ({ data }) => {
      this.enqueueBase64Data(data)
    })

    this.handleEvent("terminal_scrollback", ({ data }) => {
      this.enqueueBase64Data(data)
    })

    this.handleEvent("terminal_ended", ({ exit_code }) => {
      this.flushWriteQueueNow()
      this.term.write(`\r\n\x1b[1;33m--- Process exited with code ${exit_code} ---\x1b[0m\r\n`)
    })
  },

  setupParserHardening() {
    try {
      const parser = this.term?.parser
      if (!parser || typeof parser.registerCsiHandler !== "function") {
        return
      }

      const ansiDisp = parser.registerCsiHandler(
        { intermediates: "$", final: "p" },
        (params) => {
          const mode = (params && params[0]) || 0
          this.pushEvent("terminal_input", { data: btoa(`\x1b[${mode};0$y`) })
          return true
        }
      )

      const decDisp = parser.registerCsiHandler(
        { prefix: "?", intermediates: "$", final: "p" },
        (params) => {
          const mode = (params && params[0]) || 0
          this.pushEvent("terminal_input", { data: btoa(`\x1b[?${mode};0$y`) })
          return true
        }
      )

      this.parserDisposables.push(ansiDisp, decDisp)
      this.metrics.parserHardeningEnabled = true
    } catch (error) {
      console.warn("XTerm parser hardening unavailable", error)
    }
  },

  decodeBase64Bytes(data) {
    if (!data) return null

    try {
      const binary = atob(data)
      const bytes = new Uint8Array(binary.length)
      for (let i = 0; i < binary.length; i += 1) {
        bytes[i] = binary.charCodeAt(i)
      }
      return bytes
    } catch (error) {
      this.metrics.decodeErrors += 1
      console.warn("XTerm decode error", error)
      return null
    }
  },

  isNearBottom() {
    const buffer = this.term?.buffer?.active
    if (!buffer) return true
    return buffer.baseY - buffer.viewportY <= 2
  },

  enqueueBase64Data(data) {
    const bytes = this.decodeBase64Bytes(data)
    if (!bytes || bytes.length === 0) return

    this.writeQueue.push(bytes)
    this.queuedBytes += bytes.length
    this.metrics.queuedBytes += bytes.length

    if (this.writeFrame === null) {
      this.writeFrame = requestAnimationFrame(() => {
        this.writeFrame = null
        this.flushWriteQueue()
      })
    }
  },

  flushWriteQueueNow() {
    if (this.writeFrame !== null) {
      cancelAnimationFrame(this.writeFrame)
      this.writeFrame = null
    }
    this.flushWriteQueue()
  },

  flushWriteQueue() {
    if (!this.term || this.writeQueue.length === 0) return

    const stickToBottom = this.isNearBottom()
    const total = this.queuedBytes
    const merged = new Uint8Array(total)
    let offset = 0

    for (const chunk of this.writeQueue) {
      merged.set(chunk, offset)
      offset += chunk.length
    }

    this.writeQueue = []
    this.queuedBytes = 0
    this.metrics.queueFlushes += 1

    try {
      this.term.write(merged)
      if (stickToBottom) {
        this.term.scrollToBottom()
      }
    } catch (error) {
      this.metrics.writeErrors += 1
      console.warn("XTerm write error", error)
    }
  },

  scheduleFit() {
    if (this.fitDebounceTimer) {
      clearTimeout(this.fitDebounceTimer)
    }

    this.fitDebounceTimer = setTimeout(() => {
      this.fitDebounceTimer = null
      if (this.fitFrame !== null) {
        cancelAnimationFrame(this.fitFrame)
      }
      this.fitFrame = requestAnimationFrame(() => {
        this.fitFrame = null
        this.performFit()
      })
    }, FIT_DEBOUNCE_MS)
  },

  performFit() {
    if (!this.term || !this.fitAddon) return

    const width = this.el?.clientWidth || 0
    const height = this.el?.clientHeight || 0
    if (width < MIN_RENDERABLE_WIDTH_PX || height < MIN_RENDERABLE_HEIGHT_PX) {
      this.metrics.fitSkips += 1
      return
    }

    try {
      this.fitAddon.fit()
    } catch (error) {
      this.metrics.fitErrors += 1
      console.warn("XTerm fit error", error)
    }
  },

  destroyed() {
    this.flushWriteQueueNow()

    if (this.fitDebounceTimer) {
      clearTimeout(this.fitDebounceTimer)
      this.fitDebounceTimer = null
    }
    if (this.fitFrame !== null) {
      cancelAnimationFrame(this.fitFrame)
      this.fitFrame = null
    }
    if (this.writeFrame !== null) {
      cancelAnimationFrame(this.writeFrame)
      this.writeFrame = null
    }

    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
    }
    if (this.parserDisposables && this.parserDisposables.length > 0) {
      for (const disposable of this.parserDisposables) {
        try {
          disposable?.dispose?.()
        } catch {}
      }
      this.parserDisposables = []
    }
    if (this.term) {
      this.term.dispose()
    }
    if (window.__algedoniaTerminalMetrics) {
      delete window.__algedoniaTerminalMetrics[this.el.id]
    }
  }
}

export default XTerm
