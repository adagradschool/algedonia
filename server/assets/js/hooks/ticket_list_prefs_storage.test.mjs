import assert from "node:assert/strict"
import test from "node:test"

import {
  parseStoredPrefs,
  sanitizePersistedPrefs,
  storageKeyForWorkspace
} from "./ticket_list_prefs_storage.mjs"

test("parses persisted per-status sort preferences and keeps workspace-scoped storage keys", () => {
  const prefs = parseStoredPrefs(JSON.stringify({
    view_mode: "list",
    sort_preferences: {
      backlog: {sort_by: "title", sort_order: "desc"},
      completed: {sort_by: "updated_at", sort_order: "desc"}
    }
  }))

  assert.equal(storageKeyForWorkspace("demo"), "algedonia:ticket-list-prefs:demo")
  assert.equal(prefs.view_mode, "list")
  assert.deepEqual(prefs.sort_preferences.backlog, {sort_by: "title", sort_order: "desc"})
  assert.deepEqual(prefs.sort_preferences.completed, {sort_by: "updated_at", sort_order: "desc"})
  assert.deepEqual(prefs.sort_preferences.in_progress, {sort_by: "updated_at", sort_order: "desc"})
})

test("legacy global sort payloads do not drive ordering anymore", () => {
  const prefs = parseStoredPrefs(JSON.stringify({
    view_mode: "board",
    sort_by: "title",
    sort_order: "desc"
  }))

  assert.deepEqual(prefs, {view_mode: "board"})
})

test("invalid current-format sort values fall back to safe defaults", () => {
  const prefs = parseStoredPrefs(JSON.stringify({
    sort_preferences: {
      backlog: {sort_by: "unknown", sort_order: "sideways"},
      completed: "bad"
    }
  }))

  assert.deepEqual(prefs.sort_preferences.backlog, {sort_by: "updated_at", sort_order: "desc"})
  assert.deepEqual(prefs.sort_preferences.completed, {
    sort_by: "updated_at",
    sort_order: "desc"
  })
})

test("persist sanitization keeps only supported view and sort payload fields", () => {
  const prefs = sanitizePersistedPrefs({
    view_mode: "list",
    sort_preferences: {
      backlog: {sort_by: "title", sort_order: "asc"}
    },
    sort_by: "priority"
  })

  assert.deepEqual(prefs, {
    view_mode: "list",
    sort_preferences: {
      backlog: {sort_by: "title", sort_order: "asc"},
      planning: {sort_by: "updated_at", sort_order: "desc"},
      in_progress: {sort_by: "updated_at", sort_order: "desc"},
      in_review: {sort_by: "updated_at", sort_order: "desc"},
      halted: {sort_by: "updated_at", sort_order: "desc"},
      completed: {sort_by: "updated_at", sort_order: "desc"},
      archived: {sort_by: "updated_at", sort_order: "desc"}
    }
  })
})
