/**
 * DagGraph hook — renders a DAG as SVG with topological layout.
 * No external dependencies.
 */
const DagGraph = {
  mounted() {
    const data = JSON.parse(this.el.dataset.graph)
    this.render(data)

    this.handleEvent("dag_render", (data) => {
      this.render(data)
    })
  },

  render(data) {
    const { nodes, edges } = data
    if (!nodes || nodes.length === 0) {
      this.el.innerHTML = '<p style="color:#6B7280;text-align:center;padding:2rem;">No loops yet.</p>'
      return
    }

    const nodeMap = new Map(nodes.map(n => [n.id, n]))
    const layers = this.computeLayers(nodes, edges)
    const positions = this.layout(layers, nodes)

    const NODE_W = 180
    const NODE_H = 56
    const PAD = 40
    const maxX = Math.max(...Object.values(positions).map(p => p.x)) + NODE_W + PAD
    const maxY = Math.max(...Object.values(positions).map(p => p.y)) + NODE_H + PAD

    let svg = `<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%" viewBox="0 0 ${maxX} ${maxY}" style="min-width:${maxX}px;min-height:${maxY}px">`

    // Draw edges
    for (const edge of edges) {
      const from = positions[edge.from]
      const to = positions[edge.to]
      if (!from || !to) continue

      const x1 = from.x + NODE_W
      const y1 = from.y + NODE_H / 2
      const x2 = to.x
      const y2 = to.y + NODE_H / 2
      const cx = (x1 + x2) / 2

      svg += `<path d="M${x1},${y1} C${cx},${y1} ${cx},${y2} ${x2},${y2}" fill="none" stroke="#4B5563" stroke-width="1.5" />`
      // Arrowhead
      svg += `<polygon points="${x2},${y2} ${x2 - 6},${y2 - 4} ${x2 - 6},${y2 + 4}" fill="#4B5563" />`
    }

    // Draw nodes
    for (const node of nodes) {
      const pos = positions[node.id]
      if (!pos) continue

      svg += `<g class="dag-node" data-id="${node.id}" style="cursor:pointer">`
      svg += `<rect x="${pos.x}" y="${pos.y}" width="${NODE_W}" height="${NODE_H}" rx="6" fill="#1F2937" stroke="${node.color}" stroke-width="2" />`
      svg += `<circle cx="${pos.x + 14}" cy="${pos.y + 18}" r="5" fill="${node.color}" />`

      const title = node.title || ""
      svg += `<text x="${pos.x + 26}" y="${pos.y + 19}" fill="#E5E7EB" font-size="12" dominant-baseline="middle" font-family="ui-monospace, monospace">${this.escapeHtml(title)}</text>`

      // Status label
      const statusLabel = node.status_label || node.status
      svg += `<text x="${pos.x + 26}" y="${pos.y + 40}" fill="${node.color}" font-size="10" dominant-baseline="middle" font-family="ui-monospace, monospace">${this.escapeHtml(statusLabel)}</text>`
      svg += `</g>`
    }

    svg += `</svg>`
    this.el.innerHTML = svg

    // Click handlers
    this.el.querySelectorAll('.dag-node').forEach(g => {
      g.addEventListener('click', () => {
        const id = g.dataset.id
        const workspaceSlug = this.el.dataset.workspaceSlug
        const ticketRef = this.el.dataset.ticketRef
        window.location = `/w/${encodeURIComponent(workspaceSlug)}/tickets/${encodeURIComponent(ticketRef)}/loops/${encodeURIComponent(id)}`
      })
    })
  },

  computeLayers(nodes, edges) {
    // Compute longest path from roots (nodes with no incoming edges)
    const incoming = new Map(nodes.map(n => [n.id, []]))
    const outgoing = new Map(nodes.map(n => [n.id, []]))

    for (const e of edges) {
      if (incoming.has(e.to)) incoming.get(e.to).push(e.from)
      if (outgoing.has(e.from)) outgoing.get(e.from).push(e.to)
    }

    const depth = new Map()

    const computeDepth = (id) => {
      if (depth.has(id)) return depth.get(id)
      const parents = incoming.get(id) || []
      const d = parents.length === 0 ? 0 : Math.max(...parents.map(p => computeDepth(p))) + 1
      depth.set(id, d)
      return d
    }

    nodes.forEach(n => computeDepth(n.id))
    return depth
  },

  layout(layers, nodes) {
    const COL_GAP = 240
    const ROW_GAP = 64
    const PAD = 40

    // Group by layer
    const byLayer = new Map()
    for (const node of nodes) {
      const d = layers.get(node.id) || 0
      if (!byLayer.has(d)) byLayer.set(d, [])
      byLayer.get(d).push(node.id)
    }

    const positions = {}
    for (const [layer, ids] of byLayer) {
      ids.forEach((id, i) => {
        positions[id] = {
          x: PAD + layer * COL_GAP,
          y: PAD + i * ROW_GAP
        }
      })
    }
    return positions
  },

  escapeHtml(str) {
    return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
  }
}

export default DagGraph
