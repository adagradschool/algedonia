import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import "@xterm/xterm/css/xterm.css"

const FIT_DEBOUNCE_MS = 60
const MIN_RENDERABLE_WIDTH_PX = 24
const MIN_RENDERABLE_HEIGHT_PX = 24
const WS_RECONNECT_MS = 1200

const FRAME_INPUT = 0x00
const FRAME_CONTROL = 0x01

function ensureTerminalMetricsStore() {
  if (!window.__algedoniaTerminalMetrics) {
    window.__algedoniaTerminalMetrics = {}
  }
  return window.__algedoniaTerminalMetrics
}

function wsUrlWithParams(baseUrl, loopId, token) {
  if (!baseUrl || !loopId || !token) return null

  try {
    const normalized =
      baseUrl.startsWith("/")
        ? `${window.location.protocol === "https:" ? "wss" : "ws"}://${window.location.host}${baseUrl}`
        : baseUrl
    const url = new URL(normalized)
    url.searchParams.set("loop_id", loopId)
    url.searchParams.set("token", token)
    return url.toString()
  } catch (_) {
    return null
  }
}

const XTerm = {
  mounted() {
    this.destroying = false
    this.ws = null
    this.wsConnected = false
    this.reconnectTimer = null
    this.encoder = new TextEncoder()

    this.loopId = this.el.dataset.loopId || ""
    this.terminalWsUrl = this.el.dataset.terminalWsUrl || ""
    this.terminalWsToken = this.el.dataset.terminalWsToken || ""

    this.metrics = {
      writeErrors: 0,
      decodeErrors: 0,
      queueFlushes: 0,
      queuedBytes: 0,
      fitSkips: 0,
      fitErrors: 0,
      parserHardeningEnabled: false,
      wsReconnects: 0,
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
        selectionBackground: "#33467c",
      },
      convertEol: true,
      scrollback: 10000,
    })

    this.fitAddon = new FitAddon()
    this.term.loadAddon(this.fitAddon)
    this.term.open(this.el)
    this.setupParserHardening()
    this.scheduleFit()

    this.connectTerminalSocket()

    this.term.onData((data) => {
      const bytes = this.encoder.encode(data)
      this.sendInputFrame(bytes)
    })

    this.resizeObserver = new ResizeObserver(() => {
      this.scheduleFit()
    })
    this.resizeObserver.observe(this.el)

    this.handleEvent("terminal_scrollback", ({ data }) => {
      this.clearAndWriteScrollback(data)
    })

    this.handleEvent("terminal_ended", ({ exit_code }) => {
      this.flushWriteQueueNow()
      this.term.write(`\r\n\x1b[1;33m--- Process exited with code ${exit_code} ---\x1b[0m\r\n`)
    })
  },

  connectTerminalSocket() {
    const url = wsUrlWithParams(this.terminalWsUrl, this.loopId, this.terminalWsToken)
    if (!url) {
      return
    }

    try {
      this.ws = new WebSocket(url)
      this.ws.binaryType = "arraybuffer"
    } catch (_) {
      this.scheduleReconnect()
      return
    }

    this.ws.onopen = () => {
      this.wsConnected = true
      this.sendResizeFrame()
    }

    this.ws.onmessage = (event) => {
      const data = event.data
      if (!(data instanceof ArrayBuffer)) return
      const bytes = new Uint8Array(data)
      if (bytes.length <= 1 || bytes[0] !== FRAME_INPUT) return
      this.enqueueBytes(bytes.subarray(1))
    }

    this.ws.onclose = () => {
      this.wsConnected = false
      this.scheduleReconnect()
    }

    this.ws.onerror = () => {
      this.wsConnected = false
    }
  },

  scheduleReconnect() {
    if (this.destroying) return
    if (this.reconnectTimer) return
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null
      this.metrics.wsReconnects += 1
      this.connectTerminalSocket()
    }, WS_RECONNECT_MS)
  },

  sendInputFrame(bytes) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN || !(bytes instanceof Uint8Array)) {
      return false
    }
    const framed = new Uint8Array(bytes.length + 1)
    framed[0] = FRAME_INPUT
    framed.set(bytes, 1)
    this.ws.send(framed)
    return true
  },

  sendControlFrame(payload) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false
    const controlBytes = this.encoder.encode(JSON.stringify(payload))
    const framed = new Uint8Array(controlBytes.length + 1)
    framed[0] = FRAME_CONTROL
    framed.set(controlBytes, 1)
    this.ws.send(framed)
    return true
  },

  sendResizeFrame() {
    if (!this.term) return
    this.sendControlFrame({
      type: "resize",
      cols: this.term.cols,
      rows: this.term.rows,
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
          this.sendInputFrame(this.encoder.encode(`\x1b[${mode};0$y`))
          return true
        }
      )

      const decDisp = parser.registerCsiHandler(
        { prefix: "?", intermediates: "$", final: "p" },
        (params) => {
          const mode = (params && params[0]) || 0
          this.sendInputFrame(this.encoder.encode(`\x1b[?${mode};0$y`))
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

  enqueueBytes(bytes) {
    if (!(bytes instanceof Uint8Array) || bytes.length === 0) return

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

  clearAndWriteScrollback(data) {
    this.flushWriteQueueNow()
    if (this.term) {
      this.term.reset()
    }
    this.enqueueBase64Data(data)
  },

  enqueueBase64Data(data) {
    const bytes = this.decodeBase64Bytes(data)
    if (!bytes || bytes.length === 0) return
    this.enqueueBytes(bytes)
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
      this.sendResizeFrame()
    } catch (error) {
      this.metrics.fitErrors += 1
      console.warn("XTerm fit error", error)
    }
  },

  destroyed() {
    this.destroying = true
    this.flushWriteQueueNow()

    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = null
    }

    if (this.ws) {
      try {
        this.ws.close()
      } catch (_) {}
      this.ws = null
    }

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
  },
}

export default XTerm
