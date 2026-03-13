export const STORAGE_PREFIX = "algedonia:ticket-list-prefs:"

const STATUSES = [
  "backlog",
  "planning",
  "in_progress",
  "in_review",
  "halted",
  "completed",
  "archived"
]

const VALID_VIEW_MODES = new Set(["board", "list"])
const VALID_SORT_FIELDS = new Set(["priority", "inserted_at", "updated_at", "title"])
const VALID_SORT_ORDERS = new Set(["asc", "desc"])

const DEFAULT_SORT_PREFERENCES = Object.freeze({
  backlog: Object.freeze({sort_by: "priority", sort_order: "asc"}),
  planning: Object.freeze({sort_by: "priority", sort_order: "asc"}),
  in_progress: Object.freeze({sort_by: "priority", sort_order: "asc"}),
  in_review: Object.freeze({sort_by: "priority", sort_order: "asc"}),
  halted: Object.freeze({sort_by: "priority", sort_order: "asc"}),
  completed: Object.freeze({sort_by: "updated_at", sort_order: "desc"}),
  archived: Object.freeze({sort_by: "priority", sort_order: "asc"})
})

export function storageKeyForWorkspace(slug) {
  return `${STORAGE_PREFIX}${slug}`
}

export function defaultSortPreferences() {
  return Object.fromEntries(
    STATUSES.map((status) => [status, {...DEFAULT_SORT_PREFERENCES[status]}])
  )
}

export function normalizeSortPreferences(raw) {
  const normalized = defaultSortPreferences()

  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return normalized
  }

  for (const status of STATUSES) {
    if (!(status in raw)) continue
    normalized[status] = normalizeSortPreference(status, raw[status])
  }

  return normalized
}

export function sanitizePersistedPrefs(payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return null
  }

  const sanitized = {}

  if (VALID_VIEW_MODES.has(payload.view_mode)) {
    sanitized.view_mode = payload.view_mode
  }

  if (Object.prototype.hasOwnProperty.call(payload, "sort_preferences")) {
    sanitized.sort_preferences = normalizeSortPreferences(payload.sort_preferences)
  }

  return Object.keys(sanitized).length > 0 ? sanitized : null
}

export function parseStoredPrefs(raw) {
  if (typeof raw !== "string" || raw.trim() === "") {
    return null
  }

  try {
    const parsed = JSON.parse(raw)
    return sanitizePersistedPrefs(parsed)
  } catch (_error) {
    return null
  }
}

function normalizeSortPreference(status, raw) {
  const defaults = DEFAULT_SORT_PREFERENCES[status]

  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return {...defaults}
  }

  return {
    sort_by: VALID_SORT_FIELDS.has(raw.sort_by) ? raw.sort_by : defaults.sort_by,
    sort_order: VALID_SORT_ORDERS.has(raw.sort_order) ? raw.sort_order : defaults.sort_order
  }
}
