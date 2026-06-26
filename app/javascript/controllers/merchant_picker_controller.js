import { Controller } from "@hotwired/stimulus"

// Wraps the DS merchant select to add global search fallback + inline add form.
// When local search returns 0 results, fires AJAX to /family_merchants/search.
// When user clicks "Add [name]", shows an inline form that calls /family_merchants/create_provider.
export default class extends Controller {
  static values = { searchUrl: String, createUrl: String }

  connect() {
    // These targets are inside the DS::Select component rendered inside this wrapper
    this._selectEl = this.element.querySelector('[data-controller~="select"]')
    this._searchInput = this.element.querySelector('[data-list-filter-target="input"]')
    this._listEl = this.element.querySelector('[data-select-target="content"]')
    this._hiddenInput = this.element.querySelector('[data-select-target="input"]')
    this._button = this.element.querySelector('[data-select-target="button"]')
    this._menuEl = this.element.querySelector('[data-select-target="menu"]')

    if (!this._searchInput) return

    this._timer = null
    this._globalSection = null
    this._boundOnInput = this._onInput.bind(this)
    this._searchInput.addEventListener("input", this._boundOnInput)
  }

  disconnect() {
    if (this._searchInput && this._boundOnInput) {
      this._searchInput.removeEventListener("input", this._boundOnInput)
    }
    clearTimeout(this._timer)
  }

  _onInput() {
    clearTimeout(this._timer)
    // setTimeout(0) lets list-filter#filter run first (same-tick sync), then we check
    this._timer = setTimeout(() => this._checkAndSearch(), 0)
  }

  _checkAndSearch() {
    const query = (this._searchInput?.value || "").trim()
    this._clearGlobal()
    if (query.length < 2) return

    const visible = this._visibleItems()
    if (visible.length > 0) return  // Client results exist — don't touch

    // Debounce the actual network call
    clearTimeout(this._ajaxTimer)
    this._ajaxTimer = setTimeout(() => this._doSearch(query), 250)
  }

  _visibleItems() {
    if (!this._listEl) return []
    return Array.from(this._listEl.querySelectorAll(".filterable-item"))
      .filter(el => el.style.display !== "none")
  }

  async _doSearch(query) {
    if (!this.hasSearchUrlValue) return
    try {
      const url = `${this.searchUrlValue}?q=${encodeURIComponent(query)}`
      const resp = await fetch(url, {
        headers: { Accept: "application/json", "X-Requested-With": "XMLHttpRequest" }
      })
      if (!resp.ok) return
      const results = await resp.json()
      this._renderGlobal(results, query)
    } catch (e) {
      console.warn("merchant-picker search:", e.message)
    }
  }

  _renderGlobal(results, query) {
    if (!this._menuEl) return
    const section = document.createElement("div")
    section.className = "border-t border-secondary mt-1 pt-1"

    if (results.length > 0) {
      const header = document.createElement("div")
      header.className = "px-3 py-1 text-xs text-secondary font-medium"
      header.textContent = "Global merchants"
      section.appendChild(header)

      for (const m of results) {
        const item = document.createElement("div")
        item.className = "text-primary text-sm cursor-pointer flex items-center gap-2 px-3 py-2 rounded-lg hover:bg-container-inset-hover"

        const icon = m.logo_url
          ? `<img src="${this._esc(m.logo_url)}" class="w-6 h-6 rounded-full border border-secondary" loading="lazy" />`
          : `<span class="w-6 h-6 rounded-full bg-container-inset border border-secondary flex items-center justify-center text-xs font-medium shrink-0">${this._esc(m.name?.[0]?.toUpperCase() || "?")}</span>`
        item.innerHTML = `${icon}<span>${this._esc(m.name)}</span>`
        item.addEventListener("click", () => this._pick(m.id, m.name))
        section.appendChild(item)
      }
    }

    // "Add [name]" button always shown when global search runs
    const addBtn = document.createElement("button")
    addBtn.type = "button"
    addBtn.className = "w-full text-left px-3 py-2 text-sm cursor-pointer hover:bg-container-inset-hover rounded-lg flex items-center gap-1"
    addBtn.innerHTML = `<span class="font-bold mr-1">+</span> Add &ldquo;${this._esc(query)}&rdquo;`
    addBtn.addEventListener("click", () => this._showAddForm(query))
    section.appendChild(addBtn)

    this._globalSection = section
    this._menuEl.appendChild(section)
  }

  _clearGlobal() {
    clearTimeout(this._ajaxTimer)
    if (this._globalSection) { this._globalSection.remove(); this._globalSection = null }
    if (this._addFormEl) { this._addFormEl.remove(); this._addFormEl = null }
  }

  _showAddForm(name) {
    if (this._addFormEl) { this._addFormEl.remove(); this._addFormEl = null }
    if (!this._menuEl) return

    const wrap = document.createElement("div")
    wrap.className = "border-t border-secondary mt-1 pt-2 px-3 pb-3 space-y-2"
    wrap.innerHTML = `
      <p class="text-xs font-medium text-secondary">New merchant</p>
      <input data-field="name" type="text" value="${this._esc(name)}" placeholder="Merchant name"
             class="block w-full text-sm px-3 py-1.5 rounded-lg border border-secondary bg-container focus:outline-none focus:ring-1" />
      <input data-field="url" type="url" placeholder="Website URL (optional — AI verifies)"
             class="block w-full text-sm px-3 py-1.5 rounded-lg border border-secondary bg-container focus:outline-none focus:ring-1" />
      <div class="flex gap-2 pt-1">
        <button data-btn="add" type="button"
                class="px-3 py-1.5 text-sm rounded-lg bg-blue-600 text-white hover:bg-blue-700 focus:outline-none">
          Add
        </button>
        <button data-btn="cancel" type="button"
                class="px-3 py-1.5 text-sm rounded-lg border border-secondary text-secondary hover:text-primary focus:outline-none">
          Cancel
        </button>
      </div>
    `

    wrap.querySelector("[data-btn='add']").addEventListener("click", () => {
      const n = wrap.querySelector("[data-field='name']").value.trim()
      const u = wrap.querySelector("[data-field='url']").value.trim()
      this._submitAdd(n, u, wrap)
    })
    wrap.querySelector("[data-btn='cancel']").addEventListener("click", () => {
      wrap.remove()
      this._addFormEl = null
    })

    this._addFormEl = wrap
    this._menuEl.appendChild(wrap)
  }

  async _submitAdd(name, url, formEl) {
    if (!name) return
    if (!this.hasCreateUrlValue) return

    const addBtn = formEl.querySelector("[data-btn='add']")
    addBtn.disabled = true
    addBtn.textContent = "Adding…"

    try {
      const csrf = document.querySelector('meta[name="csrf-token"]')?.content || ""
      const body = new FormData()
      body.append("name", name)
      if (url) body.append("url", url)
      body.append("authenticity_token", csrf)

      const resp = await fetch(this.createUrlValue, {
        method: "POST",
        headers: { Accept: "application/json", "X-Requested-With": "XMLHttpRequest" },
        body
      })

      const data = await resp.json()
      if (!resp.ok) {
        addBtn.disabled = false
        addBtn.textContent = "Add"
        alert(data.error || "Failed to create merchant")
        return
      }

      this._pick(data.id, data.name)
    } catch (e) {
      addBtn.disabled = false
      addBtn.textContent = "Add"
      console.error("merchant-picker create:", e.message)
    }
  }

  _pick(id, name) {
    // Update the hidden input value that the DS::Select component manages
    if (this._hiddenInput) {
      this._hiddenInput.value = id
      this._hiddenInput.dispatchEvent(new Event("change", { bubbles: true }))
    }
    // Update the visible button label
    if (this._button) this._button.textContent = name

    // Trigger form-dropdown#onSelect (same element that has data-action="dropdown:select->form-dropdown#onSelect")
    if (this._selectEl) {
      this._selectEl.dispatchEvent(new CustomEvent("dropdown:select", {
        detail: { value: id, label: name },
        bubbles: true
      }))
    }

    // Close the select menu
    if (this._selectEl) {
      const ctrl = this.application.getControllerForElementAndIdentifier(this._selectEl, "select")
      if (ctrl) ctrl.close()
    }

    this._clearGlobal()
  }

  _esc(str) {
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
  }
}
