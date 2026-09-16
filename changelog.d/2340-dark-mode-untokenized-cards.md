### Fixed

- Account, Security, Audit log, Help and every Admin page now follow dark
  mode (#2340). Those pages predated the console's CSS-variable theme
  (`assets/css/tokens.css`) and were still built on literal Tailwind
  `bg-white` / `border-zinc-*` / `text-zinc-*` classes, which render the same
  color in both themes. `<body>`'s text color *is* tokenized, so any
  unstyled text inside one of those cards inherited dark mode's near-white
  primary color while the card itself stayed white — pale, near-invisible
  text on a card that never left light mode. Switched the affected classes
  to the `var(--color-*)` arbitrary-value convention `dashboard_live/index.ex`
  already uses.
