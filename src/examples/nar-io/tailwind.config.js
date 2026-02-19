/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./public/**/*.html",
    "./src/**/*.purs",
  ],
  theme: {
    extend: {
      colors: {
        // Base colors - dark theme
        background: "#0a0a0a",
        foreground: "#fafafa",
        
        // Card/surface
        card: "#141414",
        "card-foreground": "#fafafa",
        
        // Primary - green accent
        primary: "#22c55e",
        "primary-foreground": "#0a0a0a",
        
        // Muted
        muted: "#262626",
        "muted-foreground": "#a1a1aa",
        
        // Border
        border: "#262626",
        
        // Text
        text: "#fafafa",
        
        // Status colors
        status: "#22c55e",
        warning: "#f59e0b",
        danger: "#ef4444",
      },
      fontFamily: {
        sans: ["Inter", "system-ui", "sans-serif"],
        mono: ["JetBrains Mono", "monospace"],
      },
      animation: {
        "pulse": "pulse 2s cubic-bezier(0.4, 0, 0.6, 1) infinite",
      },
    },
  },
  plugins: [],
}
