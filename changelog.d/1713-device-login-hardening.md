### Security

- Device login (`fountain auth login --device`) is harder to guess at
  (#1713). The eight-letter user code now comes from a cryptographically
  strong random source, without modulo bias (managoat_oauth 0.1.2), and
  the `/device` page limits code lookups to 20 a minute per client
  address, across accounts, sessions and LiveView reconnects (#2138).
