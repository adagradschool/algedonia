# Design Context - Project Management Dashboard

## Color Palette
- Background: #0d0e12 (main), #16171d (sidebar), #1a1b22 (cards/secondary)
- Border: #26272e
- Text Foreground: #e8e8ea
- Text Secondary: #a8aaae
- Text Muted: #666b7a
- Primary Accent: #5e6ad2 (indigo)
- Status Green: #22c55e
- Status Orange: #f97316
- Status Red: #ef4444
- Status Yellow: #eab308
- Status Cyan: #06b6d4
- Status Blue: #3b82f6

## Typography
- Primary Font: Satoshi (400, 500, 700)
- Monospace Font: Azeret Mono (400)
- Headings: Satoshi Bold/Semibold
- Body: Satoshi Regular/Medium
- Code/IDs: Azeret Mono Regular

## Reusable Components

### Sidebar Navigation
<aside class="w-64 flex-shrink-0 bg-[#16171d] border-r border-[#26272e] flex flex-col">
  <div class="p-4 flex items-center justify-between">
    <div class="flex items-center gap-2">
      <div class="w-6 h-6 bg-indigo-500 rounded flex items-center justify-center">
        <iconify-icon icon="lucide:layout-template" class="text-white text-sm"></iconify-icon>
      </div>
      <iconify-icon icon="lucide:chevron-right" class="text-xs text-gray-500"></iconify-icon>
      <img src="https://api.dicebear.com/7.x/avataaars/svg?seed=Felix" alt="User" class="w-5 h-5 rounded-full">
    </div>
    <iconify-icon icon="lucide:more-horizontal" class="text-gray-500 cursor-pointer"></iconify-icon>
  </div>

  <div class="px-2 py-2 space-y-1">
    <a href="#" class="flex items-center gap-3 px-3 py-1.5 text-gray-400 hover:text-white transition-colors">
      <iconify-icon icon="lucide:search" class="text-lg"></iconify-icon>
      <span class="text-sm">Search</span>
    </a>
    <a href="#" class="flex items-center gap-3 px-3 py-1.5 text-gray-400 hover:text-white transition-colors">
      <iconify-icon icon="lucide:inbox" class="text-lg"></iconify-icon>
      <span class="text-sm">Inbox</span>
    </a>
  </div>

  <div class="mt-6 px-4 mb-2">
    <span class="text-[10px] uppercase tracking-wider font-bold text-gray-500">Favorites</span>
  </div>

  <div class="mt-auto p-4 space-y-4">
    <a href="#" class="flex items-center gap-2 text-gray-500 hover:text-white text-sm">
      <iconify-icon icon="lucide:plus" class="text-lg"></iconify-icon>
      <span>Invite people</span>
    </a>
  </div>
</aside>

### Issue Row Item
<div class="issue-row flex items-center gap-4 py-3 px-3 rounded-md border border-transparent hover:border-[#26272e] transition-all cursor-pointer">
  <div class="w-4 h-4 border border-gray-600 rounded-sm"></div>
  <iconify-icon icon="lucide:bar-chart-2" class="text-gray-500 rotate-90 text-sm"></iconify-icon>
  <span class="mono text-xs text-gray-500 w-16">XDM-109</span>
  <iconify-icon icon="lucide:circle" class="text-green-500 text-sm"></iconify-icon>
  <span class="text-sm font-medium flex-1">Zapier integration</span>
  <div class="flex items-center gap-2">
    <span class="px-2 py-0.5 bg-[#1a1b22] border border-[#26272e] rounded-full text-[10px] text-gray-400 flex items-center gap-1.5">
      <div class="w-1.5 h-1.5 rounded-full bg-blue-400"></div> API
    </span>
    <span class="text-[10px] text-gray-500 ml-2">Oct 17</span>
    <img src="https://api.dicebear.com/7.x/avataaars/svg?seed=Max" class="w-5 h-5 rounded-full ml-2 opacity-50">
  </div>
</div>

### Header Section
<header class="h-14 border-b border-[#26272e] flex items-center justify-between px-6 bg-[#0d0e12]">
  <div class="flex items-center gap-4">
    <h1 class="text-sm font-medium">Active issues</h1>
    <span class="flex items-center gap-1 text-xs text-gray-500">
      <iconify-icon icon="lucide:triangle" class="text-[8px] rotate-180"></iconify-icon>
      43
    </span>
    <button class="flex items-center gap-1.5 px-2 py-1 bg-[#1a1b22] border border-[#26272e] rounded text-xs text-gray-400 hover:text-white transition-colors">
      <iconify-icon icon="lucide:filter" class="text-sm"></iconify-icon>
      Filter
    </button>
  </div>
  <div class="flex items-center">
    <div class="flex bg-[#5e6ad2] hover:bg-[#4f59b0] text-white rounded overflow-hidden cursor-pointer">
      <button class="px-3 py-1 text-sm font-medium border-r border-black/10">+</button>
      <button class="px-1.5 py-1">
        <iconify-icon icon="lucide:chevron-down" class="text-xs"></iconify-icon>
      </button>
    </div>
  </div>
</header>

## Design Features
- Dark theme with professional aesthetic
- Modular sidebar with collapsible sections
- Issue list with status indicators and tags
- Floating cycles panel with embedded chart
- Smooth hover states and transitions
- Icon system via Iconify library
- Responsive grid-based layout
- Status badges with color-coded categories
- User avatars with opacity variations
