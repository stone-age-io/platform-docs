import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';

mermaid.initialize({
  startOnLoad: false,
  securityLevel: "loose",
  theme: "default", // Force 'default' theme logic for all modes
});

// This is the magic line that makes it work with Material for MkDocs
window.mermaid = mermaid;
