const SUPPORTED_IMAGE_EXTENSIONS = new Set([
  ".png",
  ".jpg",
  ".jpeg",
  ".gif",
  ".webp",
  ".bmp",
  ".tif",
  ".tiff",
  ".avif",
  ".heic",
  ".heif",
  ".svg",
])

export const DEFAULT_TERMINAL_DROP_MAX_BYTES = 10 * 1024 * 1024

function fileExtension(name) {
  const normalized = String(name || "").toLowerCase()
  const lastDot = normalized.lastIndexOf(".")
  if (lastDot < 0) return ""
  return normalized.slice(lastDot)
}

function isSupportedImageFile(file) {
  const type = String(file?.type || "").toLowerCase()
  return type.startsWith("image/") || SUPPORTED_IMAGE_EXTENSIONS.has(fileExtension(file?.name))
}

function normalizeMaxBytes(maxBytes) {
  return Number.isInteger(maxBytes) && maxBytes > 0
    ? maxBytes
    : DEFAULT_TERMINAL_DROP_MAX_BYTES
}

function pluralize(count, singular) {
  return `${count} ${singular}${count === 1 ? "" : "s"}`
}

function joinParts(parts) {
  if (parts.length <= 1) return parts[0] || ""
  if (parts.length === 2) return `${parts[0]} and ${parts[1]}`
  return `${parts.slice(0, -1).join(", ")}, and ${parts[parts.length - 1]}`
}

function formatMaxSize(maxBytes) {
  const mb = maxBytes / (1024 * 1024)
  return Number.isInteger(mb) ? `${mb} MB` : `${mb.toFixed(1)} MB`
}

function buildDropFeedback(rejected, hasAccepted, maxBytes) {
  if (!Array.isArray(rejected) || rejected.length === 0) return null

  const counts = rejected.reduce(
    (acc, item) => {
      acc[item.reason] = (acc[item.reason] || 0) + 1
      return acc
    },
    {unsupported: 0, oversized: 0, unreadable: 0}
  )

  const parts = []
  if (counts.unsupported > 0) parts.push(pluralize(counts.unsupported, "unsupported file"))
  if (counts.oversized > 0) parts.push(pluralize(counts.oversized, "oversized file"))
  if (counts.unreadable > 0) parts.push(pluralize(counts.unreadable, "unreadable file"))

  if (parts.length === 0) return null

  let message = `${hasAccepted ? "Ignored" : "Drop rejected:"} ${joinParts(parts)}.`
  if (counts.oversized > 0) {
    message += ` Max size is ${formatMaxSize(maxBytes)} per image.`
  }

  return {
    level: hasAccepted ? "info" : "error",
    message,
  }
}

function bytesToBase64(bytes) {
  if (typeof Buffer !== "undefined") {
    return Buffer.from(bytes).toString("base64")
  }

  if (typeof btoa === "function") {
    const chunkSize = 0x8000
    let binary = ""

    for (let i = 0; i < bytes.length; i += chunkSize) {
      binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize))
    }

    return btoa(binary)
  }

  throw new Error("Base64 encoding is unavailable")
}

export function hasPotentialTerminalFileDrop(dataTransfer) {
  if (!dataTransfer) return false
  const types = Array.from(dataTransfer.types || [])
  return types.includes("Files") || Array.from(dataTransfer.files || []).length > 0
}

export function classifyTerminalImageDropFiles(files, maxBytes = DEFAULT_TERMINAL_DROP_MAX_BYTES) {
  const accepted = []
  const rejected = []
  const normalizedMaxBytes = normalizeMaxBytes(maxBytes)

  for (const file of Array.from(files || [])) {
    if (!isSupportedImageFile(file)) {
      rejected.push({file, reason: "unsupported"})
      continue
    }

    if (Number.isFinite(file?.size) && file.size > normalizedMaxBytes) {
      rejected.push({file, reason: "oversized"})
      continue
    }

    accepted.push(file)
  }

  return {accepted, rejected}
}

export async function buildTerminalImageDropPayload(
  dataTransfer,
  {maxBytes = DEFAULT_TERMINAL_DROP_MAX_BYTES} = {}
) {
  const normalizedMaxBytes = normalizeMaxBytes(maxBytes)
  const {accepted, rejected} = classifyTerminalImageDropFiles(
    Array.from(dataTransfer?.files || []),
    normalizedMaxBytes
  )

  const files = []
  const rejectedFiles = [...rejected]

  for (const file of accepted) {
    try {
      if (typeof file?.arrayBuffer !== "function") {
        throw new Error("file is not readable")
      }

      const bytes = new Uint8Array(await file.arrayBuffer())
      if (bytes.byteLength > normalizedMaxBytes) {
        rejectedFiles.push({file, reason: "oversized"})
        continue
      }

      files.push({
        name: String(file.name || "image"),
        type: String(file.type || ""),
        size: bytes.byteLength,
        data: bytesToBase64(bytes),
      })
    } catch (_) {
      rejectedFiles.push({file, reason: "unreadable"})
    }
  }

  return {
    files,
    feedback: buildDropFeedback(rejectedFiles, files.length > 0, normalizedMaxBytes),
  }
}

export async function handleTerminalImageDropUpload(
  dataTransfer,
  {maxBytes = DEFAULT_TERMINAL_DROP_MAX_BYTES, pushUpload, pushFeedback} = {}
) {
  if (!hasPotentialTerminalFileDrop(dataTransfer)) return false

  const {files, feedback} = await buildTerminalImageDropPayload(dataTransfer, {maxBytes})

  if (feedback && typeof pushFeedback === "function") {
    pushFeedback(feedback)
  }

  if (files.length === 0 || typeof pushUpload !== "function") {
    return false
  }

  pushUpload({files})
  return true
}
