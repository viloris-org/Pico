# RunaDB Product Boundary

RunaDB consists of two independently released products: RunaDB Server and RunaDB Client. They
cooperate only through the versioned RunaDB wire protocol, RunaDB SQL, and the public
error model; they do not share a data directory, storage implementation, or
in-process API.

| Product | Responsibilities | Owns | Not responsible for |
| --- | --- | --- | --- |
| RunaDB Server | Accepts connections, executes RunaDB SQL, commits transactions, maintains the data directory, and performs recovery | Data, catalog, transactions, WAL, durability, recovery, and server configuration | CLI, language drivers, ORMs, and interactive tools |
| RunaDB Client | Provides the CLI, drivers, and developer tools, and encodes user operations as the RunaDB wire protocol | Local interaction, connection configuration, protocol encoding/decoding, and client-side error presentation | Data directories, storage formats, transaction commit, and durability implementation |

## Compatibility

The two products are built, versioned, released, and rolled back independently. Each
version must declare the supported RunaDB wire-protocol versions and RunaDB SQL
capabilities. Compatibility is verified by the `RunaDB Client version x RunaDB Server version`
contract tests; it does not depend on matching version numbers or a shared codebase.

This repository co-locates RunaDB Server and RunaDB Client under `src/` and
`clint/` respectively. The current `psql` connection is used solely to validate
the temporary PostgreSQL adapter and is not a commitment to support PostgreSQL
clients.

See [ADR-0010](adr/0010-client-server-product-boundary.md) for the complete decision.
