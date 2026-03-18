const FILE_URI_TYPES = ["text/uri-list", "public.file-url", "text/plain"]
const FILE_URI_FALLBACK_TYPES = ["text/plain"]
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

function parseUriPayload(payload) {
  return String(payload || "")
    .split(/\r?\n/)
    .map((entry) => entry.trim())
    .filter((entry) => entry !== "" && !entry.startsWith("#"))
}

function getTransferData(dataTransfer, type) {
  if (!dataTransfer || typeof dataTransfer.getData !== "function") return ""

  try {
    return dataTransfer.getData(type)
  } catch (_) {
    return ""
  }
}

function supportedImageExtension(path) {
  const normalized = String(path || "").toLowerCase()
  const lastDot = normalized.lastIndexOf(".")
  if (lastDot < 0) return ""
  return normalized.slice(lastDot)
}

function isSupportedImagePath(path) {
  return SUPPORTED_IMAGE_EXTENSIONS.has(supportedImageExtension(path))
}

function isSupportedImageType(type) {
  return String(type || "").toLowerCase().startsWith("image/")
}

function isSupportedImageEntry(path, file) {
  return (
    isSupportedImageType(file?.type) ||
    isSupportedImagePath(path) ||
    isSupportedImagePath(file?.name)
  )
}

export function hasPotentialTerminalFileDrop(dataTransfer) {
  if (!dataTransfer) return false

  const types = Array.from(dataTransfer.types || [])
  return (
    types.includes("Files") ||
    FILE_URI_TYPES.filter((type) => !FILE_URI_FALLBACK_TYPES.includes(type)).some((type) =>
      types.includes(type)
    )
  )
}

export function normalizeFileUriToLocalPath(uri) {
  if (!uri) return null

  try {
    const url = new URL(uri)
    if (url.protocol !== "file:") return null
    if (url.host && url.host !== "localhost") return null

    let path = decodeURIComponent(url.pathname || "")
    if (!path) return null

    if (/^\/[A-Za-z]:/.test(path)) {
      path = path.slice(1)
    }

    return path
  } catch (_) {
    return null
  }
}

export function extractDroppedImagePaths(dataTransfer) {
  if (!dataTransfer) return []

  const types = Array.from(dataTransfer.types || [])
  const candidateTypes = [
    ...FILE_URI_TYPES.filter((type) => !FILE_URI_FALLBACK_TYPES.includes(type)),
    ...(types.includes("Files") ? FILE_URI_FALLBACK_TYPES : []),
  ]

  let uriEntries = []
  for (const type of candidateTypes) {
    const entries = parseUriPayload(getTransferData(dataTransfer, type)).filter((entry) =>
      entry.toLowerCase().startsWith("file://")
    )

    if (entries.length > 0) {
      uriEntries = entries
      break
    }
  }

  if (uriEntries.length === 0) return []

  const files = Array.from(dataTransfer.files || [])
  const alignedFiles = files.length === uriEntries.length ? files : []

  return uriEntries.reduce((paths, uri, index) => {
    const path = normalizeFileUriToLocalPath(uri)
    if (!path) return paths

    const file = alignedFiles[index] || null
    if (!isSupportedImageEntry(path, file)) return paths

    paths.push(path)
    return paths
  }, [])
}

export function shellEscapePath(path) {
  return `'${String(path || "").replaceAll("'", `'\"'\"'`)}'`
}

export function buildTerminalDropInput(dataTransfer) {
  const paths = extractDroppedImagePaths(dataTransfer)
  if (paths.length === 0) return ""
  return paths.map((path) => shellEscapePath(path)).join(" ")
}

export function handleTerminalImageDrop(dataTransfer, sendInputFrame, encoder) {
  const payload = buildTerminalDropInput(dataTransfer)
  if (!payload || typeof sendInputFrame !== "function" || !encoder) return false
  return sendInputFrame(encoder.encode(payload))
}
