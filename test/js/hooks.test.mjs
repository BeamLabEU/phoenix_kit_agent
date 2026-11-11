// Behaviour of the chat panel's browser hooks (`.Feed`, `.Composer`) on a
// small fake DOM. Run by `Web.DockTest` ("the browser hooks:") with the hooks'
// own source, taken from the rendered panel, in HOOK_FEED / HOOK_COMPOSER.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"

const source = (name) => fs.readFileSync(process.env[name], "utf8")
// The colocated hook's script registers a function that returns the hook.
const load = (name) => {
  const registry = {}
  const before = globalThis.window
  globalThis.window = registry
  new Function(source(name))()
  globalThis.window = before
  return Object.values(registry)[0]()
}

// ── a fake browser: manual frames and timers, listeners that can be fired ──

function listeners() {
  const map = {}
  return {
    add: (type, fn) => (map[type] ||= []).push(fn),
    remove: (type, fn) => (map[type] = (map[type] || []).filter((f) => f !== fn)),
    fire: (type, event = {}) => (map[type] || []).slice().forEach((fn) => fn(event))
  }
}

function environment() {
  const win = listeners()
  let frames = []
  let timers = new Map()
  let nextTimer = 1

  globalThis.window = {
    addEventListener: win.add,
    removeEventListener: win.remove,
    location: {pathname: "/admin/orders"}
  }
  globalThis.requestAnimationFrame = (fn) => frames.push(fn)
  globalThis.setTimeout = (fn, ms) => {
    timers.set(nextTimer, {fn, ms})
    return nextTimer++
  }
  globalThis.clearTimeout = (id) => timers.delete(id)
  globalThis.MutationObserver = class {
    constructor(fn) { this.fn = fn; env.mutation = this }
    observe() {}
    disconnect() {}
  }
  globalThis.ResizeObserver = class {
    constructor(fn) { this.fn = fn }
    observe() {}
    disconnect() {}
  }

  const env = {
    window: win,
    // Frames the hooks asked for, run until none is left.
    frames() {
      for (let i = 0; i < 10 && frames.length > 0; i++) {
        const now = frames
        frames = []
        now.forEach((fn) => fn())
      }
    },
    timers: () => timers.size,
    // Every timer that is waiting, as if its time had come.
    fireTimers() {
      const due = [...timers.values()]
      timers = new Map()
      due.forEach(({fn}) => fn())
    }
  }
  return env
}

// A scroller: `content` is its scrollHeight, `scrollTop` is clamped as the
// browser does, and a change of either queues a scroll event for `deliver()`.
function scroller(dataset, client = 400) {
  const scroll = listeners()
  let top = 0
  let content = 0
  let pending = false
  const el = {
    dataset,
    style: {},
    clientHeight: client,
    firstElementChild: {},
    addEventListener: scroll.add,
    get scrollHeight() { return content },
    get scrollTop() { return top },
    set scrollTop(value) {
      const next = Math.max(0, Math.min(value, Math.max(0, content - client)))
      if (next !== top) pending = true
      top = next
    },
    // The browser delivers a scroll event after the position changed.
    deliver() {
      if (pending) { pending = false; scroll.fire("scroll") }
    },
    grow(height) {
      content = height
      const next = Math.min(top, Math.max(0, content - client))
      if (next !== top) pending = true
      top = next
    }
  }
  return el
}

function feed(env, conversation = "chat-a") {
  const def = load("HOOK_FEED")
  const el = scroller({conversation, restored: "0"})
  const hook = Object.assign(Object.create(def), {el})
  const rig = {
    el,
    hook,
    // The server patches the element: its data attributes, its content.
    patch({conversation, restored, height}) {
      if (conversation === undefined) delete el.dataset.conversation
      else el.dataset.conversation = conversation
      el.dataset.restored = restored
      el.grow(height)
      hook.updated()
    },
    settle() { env.frames(); el.deliver(); env.frames(); el.deliver() },
    read(distance) { el.scrollTop = el.scrollHeight - el.clientHeight - distance; el.deliver() },
    fromBottom: () => el.scrollHeight - el.scrollTop - el.clientHeight
  }
  el.grow(1000)
  hook.mounted()
  rig.settle()
  return rig
}

// ── .Feed ───────────────────────────────────────────────────────────

test("the feed starts at the end and is shown", () => {
  const rig = feed(environment())
  assert.equal(rig.fromBottom(), 0)
  assert.equal(rig.el.style.visibility, "")
})

// A re-join mounts the panel afresh, so the join renders no chat and an
// empty feed (restored back at 0); the restore that follows brings the chat
// and its messages back. `restoredBefore`: whether the browser had restored
// the panel once already since the hook mounted.
for (const restoredBefore of [true, false]) {
  const how = restoredBefore ? "after a restore" : "with no restore before"

  test(`a re-join leaves a reader who scrolled up where they were (${how})`, () => {
    const rig = feed(environment())
    if (restoredBefore) rig.patch({conversation: "chat-a", restored: "1", height: 1000})
    rig.read(500)
    assert.equal(rig.fromBottom(), 500)

    rig.patch({conversation: undefined, restored: "0", height: 0})
    rig.el.deliver()
    rig.patch({conversation: "chat-a", restored: "1", height: 1000})
    rig.settle()

    assert.equal(rig.fromBottom(), 500)
    assert.equal(rig.el.style.visibility, "")

    // Still a reader of older messages: a new message does not pull them down.
    rig.el.grow(1100)
    rig.hook.observer.fn()
    assert.equal(rig.fromBottom(), 600)
  })

  test(`a re-join leaves a reader who was at the end at the end (${how})`, () => {
    const rig = feed(environment())
    if (restoredBefore) rig.patch({conversation: "chat-a", restored: "1", height: 1000})
    rig.patch({conversation: undefined, restored: "0", height: 0})
    rig.el.deliver()
    rig.patch({conversation: "chat-a", restored: "1", height: 1000})
    rig.settle()

    assert.equal(rig.fromBottom(), 0)
    assert.equal(rig.el.style.visibility, "")

    rig.el.grow(1100)
    rig.hook.observer.fn()
    assert.equal(rig.fromBottom(), 0)
  })
}

test("another chat starts at its end, whatever the reader did in the last", () => {
  const rig = feed(environment())
  rig.read(500)

  rig.patch({conversation: "chat-b", restored: "0", height: 2000})
  rig.settle()

  assert.equal(rig.fromBottom(), 0)
  assert.equal(rig.el.style.visibility, "")
})

test("a restored chat whose messages come in a later patch keeps the reader's place", () => {
  const rig = feed(environment())
  rig.read(500)

  rig.patch({conversation: undefined, restored: "0", height: 0})
  rig.el.deliver()
  // The chat is back, its messages are not yet.
  rig.patch({conversation: "chat-a", restored: "1", height: 100})
  rig.settle()
  rig.patch({conversation: "chat-a", restored: "1", height: 1000})
  rig.settle()

  assert.equal(rig.fromBottom(), 500)
  rig.el.grow(1100)
  rig.hook.observer.fn()
  assert.equal(rig.fromBottom(), 600)
})

test("a restored chat whose messages come as a change of the content keeps the reader's place", () => {
  const rig = feed(environment())
  rig.read(500)

  rig.patch({conversation: undefined, restored: "0", height: 0})
  rig.el.deliver()
  rig.patch({conversation: "chat-a", restored: "1", height: 100})
  rig.settle()
  rig.el.grow(1000)
  rig.hook.observer.fn()
  rig.settle()

  assert.equal(rig.fromBottom(), 500)
})

test("a reader who scrolls before the held place can be applied is not moved back", () => {
  const env = environment()
  const rig = feed(env)
  rig.read(500)

  rig.patch({conversation: undefined, restored: "0", height: 0})
  rig.el.deliver()
  rig.patch({conversation: "chat-a", restored: "1", height: 100})
  rig.settle()
  // The place was never applied (no content for it): after the wait, the
  // reader's own scrolling counts again.
  env.fireTimers()
  rig.el.grow(1000)
  rig.read(200)
  rig.el.grow(1100)
  rig.hook.observer.fn()
  assert.equal(rig.fromBottom(), 300)
})

test("the same chat opened again after a new chat starts at its end", () => {
  const rig = feed(environment())
  rig.read(500)

  // "New chat" empties the feed; the panel was not restored.
  rig.patch({conversation: undefined, restored: "0", height: 0})
  rig.el.deliver()
  rig.patch({conversation: "chat-a", restored: "0", height: 1000})
  rig.settle()

  assert.equal(rig.fromBottom(), 0)
})

test("a chat that comes back long after the feed was emptied starts at its end", () => {
  const rig = feed(environment())
  rig.read(500)

  rig.patch({conversation: undefined, restored: "0", height: 0})
  rig.el.deliver()
  const now = Date.now
  Date.now = () => now() + 60000
  try {
    rig.patch({conversation: "chat-a", restored: "1", height: 1000})
  } finally {
    Date.now = now
  }
  rig.settle()

  assert.equal(rig.fromBottom(), 0)
})

test("a different chat after a re-join starts at its end", () => {
  const rig = feed(environment())
  rig.read(500)

  rig.patch({conversation: undefined, restored: "0", height: 0})
  rig.el.deliver()
  rig.patch({conversation: "chat-b", restored: "1", height: 2000})
  rig.settle()

  assert.equal(rig.fromBottom(), 0)
})

test("a live navigation keeps a reader at the end there, and a reader above where they are", () => {
  const env = environment()
  const rig = feed(env)

  // At the end: the navigation resets the scroll, the feed goes back to the end.
  env.window.fire("phx:page-loading-start", {detail: {kind: "redirect"}})
  rig.el.scrollTop = 0
  rig.el.deliver()
  env.window.fire("phx:page-loading-stop")
  rig.settle()
  assert.equal(rig.fromBottom(), 0)

  // Above the end: the same reset is not the reader's doing, and what they
  // read is not pinned down either.
  rig.read(500)
  env.window.fire("phx:page-loading-start", {detail: {kind: "redirect"}})
  rig.el.deliver()
  env.window.fire("phx:page-loading-stop")
  rig.settle()
  assert.equal(rig.fromBottom(), 500)
})

test("a hidden panel does not count as a reader who left the end", () => {
  const rig = feed(environment())
  rig.el.clientHeight = 0
  rig.el.scrollTop = 0
  rig.el.deliver()
  rig.el.clientHeight = 400
  rig.el.grow(1100)
  rig.hook.observer.fn()
  assert.equal(rig.fromBottom(), 0)
})

// ── .Composer ───────────────────────────────────────────────────────

function composer({states}) {
  const env = environment()
  const def = load("HOOK_COMPOSER")
  const form = listeners()
  const page = {value: ""}
  const waiting = {value: "stale"}
  const items = states.map((state) => ({dataset: {state}}))
  const el = {
    addEventListener: () => {},
    value: "text",
    form: {
      addEventListener: form.add,
      querySelector(selector) {
        if (selector === "[data-pk-agent-page]") return page
        if (selector === "[data-pk-agent-uploads-waiting]") return waiting
        // The manager's rows that are queued or moving.
        const wanted = ["queued", "uploading"].filter((s) => selector.includes(`data-state="${s}"`))
        return items.find((item) => wanted.includes(item.dataset.state)) || null
      }
    }
  }
  const hook = Object.assign(Object.create(def), {el, handleEvent() {}})
  hook.mounted()
  form.fire("submit")
  return {env, page, waiting}
}

test("a send tells the server the page and whether a file is still on its way", () => {
  for (const states of [["queued"], ["uploading"], ["done", "queued"]]) {
    const {page, waiting} = composer({states})
    assert.equal(page.value, "/admin/orders")
    assert.equal(waiting.value, "1", states.join())
  }
})

test("paused, failed, skipped and finished files do not hold a send", () => {
  const {waiting} = composer({states: ["paused", "failed", "skipped", "done"]})
  assert.equal(waiting.value, "")
})
