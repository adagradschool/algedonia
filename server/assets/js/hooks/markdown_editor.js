import { Editor } from "@tiptap/core"
import StarterKit from "@tiptap/starter-kit"
import Placeholder from "@tiptap/extension-placeholder"
import TaskItem from "@tiptap/extension-task-item"
import TaskList from "@tiptap/extension-task-list"
import { Markdown } from "tiptap-markdown"

const MarkdownEditor = {
  mounted() {
    this.suppressPush = false
    this.pendingIncoming = null
    this.localEditAt = 0
    this.pendingTimer = null
    this.incomingCooldownMs = 700

    this.pushRubric = this.debounce(() => {
      if (this.suppressPush) return
      this.pushEvent("rubric_change", { body: this.getMarkdown() })
    }, 300)

    this.editor = new Editor({
      element: this.el,
      content: this.el.dataset.markdown || "",
      extensions: [
        StarterKit,
        TaskList,
        TaskItem.configure({
          nested: true
        }),
        Placeholder.configure({
          placeholder: "Define pass/fail criteria, edge cases, and required evidence..."
        }),
        Markdown.configure({
          transformPastedText: true,
          transformCopiedText: true,
          breaks: true
        })
      ],
      editorProps: {
        attributes: {
          class: "tiptap"
        }
      },
      onUpdate: () => {
        this.localEditAt = Date.now()
        this.pushRubric()
      }
    })

    this.onFocusIn = () => {
      this.localEditAt = Date.now()
    }

    this.onFocusOut = () => {
      window.setTimeout(() => this.flushPendingIncoming(), 0)
    }

    this.el.addEventListener("focusin", this.onFocusIn)
    this.el.addEventListener("focusout", this.onFocusOut)
  },

  updated() {
    if (!this.editor) return

    const incoming = this.el.dataset.markdown || ""
    const current = this.getMarkdown()

    if (incoming === current) return

    const focusedInEditor = this.editor.isFocused || this.el.contains(document.activeElement)
    const recentlyEdited = Date.now() - this.localEditAt < this.incomingCooldownMs

    if (focusedInEditor || recentlyEdited) {
      this.pendingIncoming = incoming
      this.schedulePendingApply()
      return
    }

    this.applyIncoming(incoming)
  },

  destroyed() {
    clearTimeout(this.pendingTimer)

    if (this.onFocusIn) {
      this.el.removeEventListener("focusin", this.onFocusIn)
    }

    if (this.onFocusOut) {
      this.el.removeEventListener("focusout", this.onFocusOut)
    }

    if (this.editor) {
      this.editor.destroy()
      this.editor = null
    }
  },

  applyIncoming(markdown) {
    this.suppressPush = true
    this.editor.commands.setContent(markdown || "")
    this.suppressPush = false
    this.pendingIncoming = null
  },

  getMarkdown() {
    return this.editor?.storage?.markdown?.getMarkdown?.() || ""
  },

  flushPendingIncoming() {
    if (!this.pendingIncoming || !this.editor) return
    if (this.el.contains(document.activeElement)) return

    const recentlyEdited = Date.now() - this.localEditAt < this.incomingCooldownMs

    if (recentlyEdited) {
      this.schedulePendingApply()
      return
    }

    this.applyIncoming(this.pendingIncoming)
  },

  schedulePendingApply() {
    clearTimeout(this.pendingTimer)
    this.pendingTimer = window.setTimeout(
      () => this.flushPendingIncoming(),
      this.incomingCooldownMs
    )
  },

  debounce(fn, wait) {
    let timer = null

    return (...args) => {
      clearTimeout(timer)
      timer = setTimeout(() => fn(...args), wait)
    }
  }
}

export default MarkdownEditor
