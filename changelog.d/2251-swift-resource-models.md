### Changed

- Generate Swift agent, environment/vault, connection, team, account/catalog/apply and admin resource models from the contract while preserving existing public names, dynamic JSON APIs and nullable request semantics. Properties these models expose for the first time decode as optional, so a response from an older server still decodes (#2251).
