import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "panel"]

  connect() {
    this.showPanel(0)
  }

  select(event) {
    const index = parseInt(event.currentTarget.dataset.index)
    this.showPanel(index)
  }

  showPanel(activeIndex) {
    this.buttonTargets.forEach((button, index) => {
      if (index === activeIndex) {
        button.style.borderBottom = "2px solid #dc2626"
        button.style.color = "#dc2626"
        button.style.fontWeight = "600"
      } else {
        button.style.borderBottom = "2px solid transparent"
        button.style.color = "#6b7280"
        button.style.fontWeight = "500"
      }
    })
    this.panelTargets.forEach((panel, index) => {
      panel.style.display = index === activeIndex ? "block" : "none"
    })
  }
}
