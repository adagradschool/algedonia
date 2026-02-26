import Editor from "@toast-ui/editor"
import "@toast-ui/editor/dist/toastui-editor.css"

const MarkdownEditor = {
  mounted() {
    this.suppressPush = false

    this.editor = new Editor({
      el: this.el,
      initialValue: this.el.dataset.markdown || "",
      initialEditType: "wysiwyg",
      previewStyle: "vertical",
      hideModeSwitch: false,
      height: "320px",
      usageStatistics: false,
      theme: "dark",
      toolbarItems: [
        ["heading", "bold", "italic", "strike"],
        ["hr", "quote"],
        ["ul", "ol", "task"],
        ["table", "link", "code", "codeblock"]
      ]
    })

    this.pushRubric = this.debounce(() => {
      if (this.suppressPush) return
      this.pushEvent("rubric_change", { body: this.editor.getMarkdown() })
    }, 300)

    this.editor.on("change", () => this.pushRubric())
  },

  updated() {
    if (!this.editor) return

    const incoming = this.el.dataset.markdown || ""
    const current = this.editor.getMarkdown()

    if (incoming !== current) {
      this.suppressPush = true
      this.editor.setMarkdown(incoming, false)
      this.suppressPush = false
    }
  },

  destroyed() {
    if (this.editor) {
      this.editor.destroy()
      this.editor = null
    }
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
