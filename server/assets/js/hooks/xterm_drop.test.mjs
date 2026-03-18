import assert from "node:assert/strict"
import test from "node:test"

import {
  buildTerminalDropInput,
  handleTerminalImageDrop,
} from "./xterm_drop.mjs"

function makeDataTransfer({types = [], files = [], payloads = {}} = {}) {
  return {
    files,
    types,
    getData(type) {
      return payloads[type] || ""
    },
  }
}

test("single image drop inserts one shell-safe local path without submitting", () => {
  const sentFrames = []
  const encoder = new TextEncoder()
  const dataTransfer = makeDataTransfer({
    files: [{name: "space name.png", type: "image/png"}],
    types: ["Files", "text/uri-list"],
    payloads: {
      "text/uri-list": "file:///tmp/space%20name.png",
    },
  })

  const inserted = handleTerminalImageDrop(
    dataTransfer,
    (bytes) => {
      sentFrames.push(bytes)
      return true
    },
    encoder
  )

  assert.equal(inserted, true)
  assert.equal(sentFrames.length, 1)
  assert.equal(new TextDecoder().decode(sentFrames[0]), "'/tmp/space name.png'")
  assert.equal(new TextDecoder().decode(sentFrames[0]).includes("\n"), false)
  assert.equal(new TextDecoder().decode(sentFrames[0]).includes("\r"), false)
})

test("multi-image drop preserves URI order and shell-escapes each path", () => {
  const payload = buildTerminalDropInput(
    makeDataTransfer({
      files: [
        {name: "first shot.png", type: "image/png"},
        {name: "two's.jpg", type: "image/jpeg"},
        {name: "notes.txt", type: "text/plain"},
      ],
      types: ["Files", "text/uri-list"],
      payloads: {
        "text/uri-list": [
          "file:///tmp/first%20shot.png",
          "file:///tmp/two%27s.jpg",
          "file:///tmp/notes.txt",
        ].join("\n"),
      },
    })
  )

  assert.equal(payload, "'/tmp/first shot.png' '/tmp/two'\"'\"'s.jpg'")
})

test("unsupported drops are ignored without throwing or sending terminal input", () => {
  let sent = false
  const dataTransfer = makeDataTransfer({
    files: [{name: "notes.txt", type: "text/plain"}],
    types: ["Files", "text/uri-list"],
    payloads: {
      "text/uri-list": "file:///tmp/notes.txt",
    },
  })

  assert.doesNotThrow(() => {
    const inserted = handleTerminalImageDrop(
      dataTransfer,
      () => {
        sent = true
        return true
      },
      new TextEncoder()
    )

    assert.equal(inserted, false)
  })

  assert.equal(sent, false)
  assert.equal(buildTerminalDropInput(dataTransfer), "")
})
