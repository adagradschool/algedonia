import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import "@xterm/xterm/css/xterm.css"
import {
  handleTerminalImageDrop,
  hasPotentialTerminalFileDrop,
} from "./xterm_drop.mjs"

const FIT_DEBOUNCE_MS = 60
const MIN_RENDERABLE_WIDTH_PX = 24
const MIN_RENDERABLE_HEIGHT_PX = 24
const WS_RECONNECT_MS = 1200
const DROP_ACTIVE_CLASS = "xterm-terminal--drag-active"

const FRAME_INPUT = 0x00
const FRAME_CONTROL = 0x01

function ensureTerminalMetricsStore() {
  if (!window.__algedoniaTerminalMetrics) {
    window.__algedoniaTerminalMetrics = {}
  }
  return window.__algedoniaTerminalMetrics
}

function wsUrlWithParams(baseUrl, loopId, token, fromSeq) {
  if (!baseUrl || !loopId || !token) return null

  try {
    const normalized =
      baseUrl.startsWith("/")
        ? `${window.location.protocol === "https:" ? "wss" : "ws"}://${window.location.host}${baseUrl}`
        : baseUrl
    const url = new URL(normalized)
    url.searchParams.set("loop_id", loopId)
    url.searchParams.set("token", token)
    if (Number.isInteger(fromSeq) && fromSeq > 0) {
      url.searchParams.set("from_seq", String(fromSeq))
    }
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
    this.hasOpenedSocket = false
    this.lastOutputSeq = 0
    this.reconnectTimer = null
    this.encoder = new TextEncoder()

    this.loopId = this.el.dataset.loopId || ""
    this.terminalWsUrl = this.el.dataset.terminalWsUrl || ""
    this.terminalWsToken = this.el.dataset.terminalWsToken || ""
    this.liveStreamEnabled = Boolean(this.loopId && this.terminalWsUrl && this.terminalWsToken)

    this.metrics = {
      writeErrors: 0,
      decodeErrors: 0,
      queueFlushes: 0,
      queuedBytes: 0,
      fitSkips: 0,
      fitErrors: 0,
      parserHardeningEnabled: false,
      wsReconnects: 0,
      seqFrames: 0,
      seqDuplicates: 0,
    }
    ensureTerminalMetricsStore()[this.el.id] = this.metrics

    this.writeQueue = []
    this.queuedBytes = 0
    this.writeFrame = null
    this.pendingCarriageReturn = false
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
    this.term.attachCustomKeyEventHandler((event) => {
      // Let Ctrl+` bubble up for sidebar toggle
      if (event.ctrlKey && event.key === "`") return false
      return true
    })
    requestAnimationFrame(() => this.term?.focus())
    this.setupParserHardening()
    this.scheduleFit()

    this.onPointerFocus = () => this.term?.focus()
    this.el.addEventListener("pointerdown", this.onPointerFocus)

    this.onDragOver = (event) => {
      if (!hasPotentialTerminalFileDrop(event.dataTransfer)) return
      event.preventDefault()
      this.el.classList.add(DROP_ACTIVE_CLASS)
    }

    this.onDragLeave = (event) => {
      if (event.currentTarget === event.target || !this.el.contains(event.relatedTarget)) {
        this.el.classList.remove(DROP_ACTIVE_CLASS)
      }
    }

    this.onDrop = (event) => {
      this.el.classList.remove(DROP_ACTIVE_CLASS)
      if (!hasPotentialTerminalFileDrop(event.dataTransfer)) return

      event.preventDefault()

      try {
        const inserted = handleTerminalImageDrop(
          event.dataTransfer,
          (bytes) => this.sendInputFrame(bytes),
          this.encoder
        )

        if (inserted) {
          this.term?.focus()
        }
      } catch (error) {
        console.warn("XTerm drop error", error)
      }
    }

    this.el.addEventListener("dragover", this.onDragOver)
    this.el.addEventListener("dragleave", this.onDragLeave)
    this.el.addEventListener("drop", this.onDrop)

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
      // Live terminals resync through sequence-based WS replay; applying a
      // full snapshot concurrently can corrupt ANSI cursor state.
      if (this.liveStreamEnabled) return
      this.clearAndWriteScrollback(data)
    })

    this.handleEvent("terminal_ended", ({ exit_code }) => {
      this.flushWriteQueueNow()
      this.flushPendingCarriageReturn()
      this.term.write(`\r\n\x1b[1;33m--- Process exited with code ${exit_code} ---\x1b[0m\r\n`)
    })

    this.handleEvent("terminal_ws_updated", ({ url, token, loop_id }) => {
      if (url === this.terminalWsUrl && token === this.terminalWsToken && loop_id === this.loopId) {
        return
      }
      this.loopId = loop_id || this.loopId
      this.terminalWsUrl = url || ""
      this.terminalWsToken = token || ""
      this.liveStreamEnabled = Boolean(this.loopId && this.terminalWsUrl && this.terminalWsToken)

      if (this.reconnectTimer) {
        clearTimeout(this.reconnectTimer)
        this.reconnectTimer = null
      }
      if (this.ws) {
        try { this.ws.close() } catch (_) {}
        this.ws = null
      }
      this.wsConnected = false
      this.connectTerminalSocket()
    })
  },

  connectTerminalSocket() {
    if (!this.liveStreamEnabled) {
      return
    }

    const fromSeq =
      Number.isInteger(this.lastOutputSeq) && this.lastOutputSeq > 0 ? this.lastOutputSeq + 1 : 1
    const url = wsUrlWithParams(this.terminalWsUrl, this.loopId, this.terminalWsToken, fromSeq)
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
      this.hasOpenedSocket = true
    }

    this.ws.onmessage = (event) => {
      const data = event.data
      if (!(data instanceof ArrayBuffer)) return
      const bytes = new Uint8Array(data)
      if (bytes.length <= 9 || bytes[0] !== FRAME_INPUT) return
      const seq = this.decodeSeq(bytes)
      this.metrics.seqFrames += 1
      if (seq !== null && seq <= this.lastOutputSeq) {
        this.metrics.seqDuplicates += 1
        return
      }
      if (seq !== null) this.lastOutputSeq = seq
      this.enqueueBytes(bytes.subarray(9))
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

  decodeSeq(bytes) {
    if (!(bytes instanceof Uint8Array) || bytes.length < 9) return null
    // Seq is encoded as 8-byte big-endian; keep precision by constraining to
    // 53-bit JS integer space.
    let seq = 0
    for (let i = 1; i <= 8; i += 1) {
      seq = seq * 256 + bytes[i]
    }
    if (!Number.isSafeInteger(seq)) return null
    return seq
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
    this.pendingCarriageReturn = false
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

  flushPendingCarriageReturn() {
    if (!this.term || !this.pendingCarriageReturn) return
    this.pendingCarriageReturn = false
    this.term.write(new Uint8Array([0x0d, 0x1b, 0x5b, 0x4b]))
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

  normalizeCarriageReturns(bytes) {
    if (!(bytes instanceof Uint8Array) || bytes.length === 0) return bytes

    const CR = 0x0d
    const LF = 0x0a
    const ESC = 0x1b
    const OPEN_BRACKET = 0x5b
    const K = 0x4b
    const out = []
    let index = 0

    // Handle a carriage return that was deferred from the previous flush.
    if (this.pendingCarriageReturn) {
      if (bytes[0] === LF) {
        out.push(CR, LF)
        index = 1
      } else {
        out.push(CR, ESC, OPEN_BRACKET, K)
      }
      this.pendingCarriageReturn = false
    }

    for (; index < bytes.length; index += 1) {
      const b = bytes[index]
      if (b !== CR) {
        out.push(b)
        continue
      }

      // Preserve CRLF pairs; normalize lone CR updates to clear-line rewrites.
      if (index + 1 < bytes.length) {
        if (bytes[index + 1] === LF) {
          out.push(CR, LF)
          index += 1
        } else {
          out.push(CR, ESC, OPEN_BRACKET, K)
        }
        continue
      }

      this.pendingCarriageReturn = true
    }

    return new Uint8Array(out)
  },

  destroyed() {
    this.destroying = true
    this.flushWriteQueueNow()
    this.flushPendingCarriageReturn()

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
    if (this.onPointerFocus) {
      this.el.removeEventListener("pointerdown", this.onPointerFocus)
    }
    if (this.onDragOver) {
      this.el.removeEventListener("dragover", this.onDragOver)
    }
    if (this.onDragLeave) {
      this.el.removeEventListener("dragleave", this.onDragLeave)
    }
    if (this.onDrop) {
      this.el.removeEventListener("drop", this.onDrop)
      this.el.classList.remove(DROP_ACTIVE_CLASS)
    }
    if (window.__algedoniaTerminalMetrics) {
      delete window.__algedoniaTerminalMetrics[this.el.id]
    }
  },
}

export default XTerm
