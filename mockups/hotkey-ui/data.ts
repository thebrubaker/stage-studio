// Fake window list for the picker mockup — mirrors `windowclip list-windows` output shape.
export type MockWindow = {
  windowId: number;
  app: string;
  title: string;
  glyph: string; // stand-in for the app icon
  // thumbnail stand-in: gradient stops
  from: string;
  to: string;
  accent?: string;
};

export const MOCK_WINDOWS: MockWindow[] = [
  { windowId: 8721, app: "Linear", title: "DIG-228 · Agent Runner Phase 2", glyph: "L", from: "#5e6ad2", to: "#26284a" },
  { windowId: 8842, app: "Chrome", title: "onbook — localhost:3000", glyph: "C", from: "#4a90d9", to: "#1d3253" },
  { windowId: 8455, app: "cmux", title: "windowclip · project-lead", glyph: "⌘", from: "#2a2d34", to: "#101114" },
  { windowId: 9012, app: "Slack", title: "#d-dev — Digital Pine", glyph: "S", from: "#611f69", to: "#2b0e2f" },
  { windowId: 8103, app: "Finder", title: "Desktop", glyph: "F", from: "#3b82c4", to: "#173350" },
  { windowId: 9204, app: "Notes", title: "Recording script", glyph: "N", from: "#c4a13b", to: "#4a3c17" },
];
