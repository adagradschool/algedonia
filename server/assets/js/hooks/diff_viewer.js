/**
 * DiffViewer — lazy-loads highlight.js and applies syntax highlighting
 * to diff code blocks. Manages inline comment form UI.
 */
let hljs = null

async function loadHighlightJS() {
  if (hljs) return hljs

  const mod = await import("highlight.js/lib/core")
  hljs = mod.default

  const [elixir, go, javascript, typescript] = await Promise.all([
    import("highlight.js/lib/languages/elixir"),
    import("highlight.js/lib/languages/go"),
    import("highlight.js/lib/languages/javascript"),
    import("highlight.js/lib/languages/typescript"),
  ])

  hljs.registerLanguage("elixir", elixir.default)
  hljs.registerLanguage("go", go.default)
  hljs.registerLanguage("javascript", javascript.default)
  hljs.registerLanguage("typescript", typescript.default)

  return hljs
}

function highlightCodeBlocks(container) {
  loadHighlightJS().then((hl) => {
    const codeBlocks = container.querySelectorAll("code[class^='language-']")
    codeBlocks.forEach((block) => {
      if (!block.dataset.highlighted) {
        hl.highlightElement(block)
        block.dataset.highlighted = "true"
      }
    })
  })
}

const DiffViewer = {
  mounted() {
    highlightCodeBlocks(this.el)
    this._setupInlineCommentForm()
  },

  updated() {
    highlightCodeBlocks(this.el)
  },

  destroyed() {
    this._removeCommentForm()
  },

  _setupInlineCommentForm() {
    this.handleEvent("close_inline_comment_form", () => {
      this._removeCommentForm()
    })
  },

  _removeCommentForm() {
    const existing = this.el.querySelector(".inline-comment-form")
    if (existing) existing.remove()
  },
}

export default DiffViewer
