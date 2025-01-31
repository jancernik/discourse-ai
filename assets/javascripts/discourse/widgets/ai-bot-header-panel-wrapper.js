import { action } from "@ember/object";
import { hbs } from "ember-cli-htmlbars";
import RenderGlimmer from "discourse/widgets/render-glimmer";
import Widget from "discourse/widgets/widget";

export default class AiBotHeaderPanelWrapper extends Widget {
  buildAttributes() {
    return { "data-click-outside": true };
  }

  html() {
    return [
      new RenderGlimmer(
        this,
        "div.widget-component-connector",
        hbs`<AiBotHeaderPanel @closePanel={{@data.closePanel}} />`,
        { closePanel: this.closePanel }
      ),
    ];
  }

  @action
  closePanel() {
    this.sendWidgetAction("hideAiBotPanel");
  }

  @action
  clickOutside() {
    this.closePanel();
  }
}
