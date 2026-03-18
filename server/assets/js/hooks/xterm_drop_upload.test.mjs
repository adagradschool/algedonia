import assert from "node:assert/strict"
import test from "node:test"

import {
  buildTerminalImageDropPayload,
  classifyTerminalImageDropFiles,
  handleTerminalImageDropUpload,
  hasPotentialTerminalFileDrop,
} from "./xterm_drop_upload.mjs"

function makeFile(name, type, bytes) {
  const value = Uint8Array.from(bytes)

  return {
    name,
    type,
    size: value.byteLength,
    async arrayBuffer() {
      return value.slice().buffer
    },
  }
}

function makeDataTransfer(files) {
  return {
    files,
    types: ["Files"],
  }
}

test("detects file drops from terminal drag payloads", () => {
  assert.equal(hasPotentialTerminalFileDrop(makeDataTransfer([])), true)
  assert.equal(hasPotentialTerminalFileDrop({files: [], types: []}), false)
  assert.equal(hasPotentialTerminalFileDrop(null), false)
})

test("builds upload payloads for supported images in deterministic drop order", async () => {
  const dataTransfer = makeDataTransfer([
    makeFile("first shot.png", "image/png", [0x66, 0x69, 0x72, 0x73, 0x74]),
    makeFile("notes.txt", "text/plain", [0x6e, 0x6f]),
    makeFile("second.webp", "image/webp", [0x73, 0x65, 0x63, 0x6f, 0x6e, 0x64]),
  ])

  const payload = await buildTerminalImageDropPayload(dataTransfer)

  assert.deepEqual(
    payload.files.map((file) => file.name),
    ["first shot.png", "second.webp"]
  )
  assert.equal(payload.files[0].data, "Zmlyc3Q=")
  assert.equal(payload.files[1].data, "c2Vjb25k")
  assert.deepEqual(payload.feedback, {
    level: "info",
    message: "Ignored 1 unsupported file.",
  })
})

test("builds upload payloads from dropped file bytes without recovering host paths", async () => {
  const dataTransfer = {
    files: [makeFile("diagram.png", "image/png", [0x64, 0x69, 0x61])],
    types: ["Files", "text/uri-list"],
    getData() {
      throw new Error("host path access should not be used")
    },
  }

  const payload = await buildTerminalImageDropPayload(dataTransfer)

  assert.equal(payload.files.length, 1)
  assert.deepEqual(Object.keys(payload.files[0]).sort(), ["data", "name", "size", "type"])
  assert.equal(payload.files[0].name, "diagram.png")
  assert.equal(payload.feedback, null)
})

test("classifies oversized images before upload encoding", () => {
  const {accepted, rejected} = classifyTerminalImageDropFiles(
    [
      {name: "ok.png", type: "image/png", size: 10},
      {name: "big.png", type: "image/png", size: 11},
    ],
    10
  )

  assert.deepEqual(accepted.map((file) => file.name), ["ok.png"])
  assert.deepEqual(rejected.map((entry) => [entry.file.name, entry.reason]), [["big.png", "oversized"]])
})

test("rejects unsupported and oversized drops without implicit submit side effects", async () => {
  const uploadEvents = []
  const feedbackEvents = []

  const inserted = await handleTerminalImageDropUpload(makeDataTransfer([
    makeFile("notes.txt", "text/plain", [0x6e]),
    makeFile("too-big.png", "image/png", [1, 2, 3, 4]),
  ]), {
    maxBytes: 3,
    pushUpload(payload) {
      uploadEvents.push(payload)
    },
    pushFeedback(feedback) {
      feedbackEvents.push(feedback)
    },
  })

  assert.equal(inserted, false)
  assert.deepEqual(uploadEvents, [])
  assert.deepEqual(feedbackEvents, [
    {
      level: "error",
      message: "Drop rejected: 1 unsupported file and 1 oversized file. Max size is 0.0 MB per image.",
    },
  ])
})

test("queues exactly one upload event for a single supported image", async () => {
  const uploadEvents = []
  const feedbackEvents = []

  const inserted = await handleTerminalImageDropUpload(
    makeDataTransfer([makeFile("photo.png", "image/png", [0x70, 0x6e, 0x67])]),
    {
      pushUpload(payload) {
        uploadEvents.push(payload)
      },
      pushFeedback(feedback) {
        feedbackEvents.push(feedback)
      },
    }
  )

  assert.equal(inserted, true)
  assert.equal(uploadEvents.length, 1)
  assert.equal(uploadEvents[0].files.length, 1)
  assert.deepEqual(feedbackEvents, [])
})
