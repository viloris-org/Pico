# RunaDB Product Boundary

RunaDB consists of two independently released products: RunaDB Server and RunaDB Client. They
cooperate only through the versioned RunaDB Wire Protocol, Runa Flow, and the public
error model; they do not share a data directory, storage implementation, or
in-process API.

| Product | Responsibilities | Owns | Not responsible for |
| --- | --- | --- | --- |
| RunaDB Server | Accepts connections, validates and executes supported Runa Flow Requests, maintains the data directory, and performs recovery | Data, catalog, transactions, WAL, durability, recovery, and server configuration | CLI, language drivers, ORMs, and interactive tools |
| RunaDB Client | Provides the CLI, drivers, and developer tools, and encodes user operations as the RunaDB wire protocol | Local interaction, connection configuration, protocol encoding/decoding, and client-side error presentation | Data directories, storage formats, transaction commit, and durability implementation |

## Compatibility

The two products are built, versioned, released, and rolled back independently. Each
version must declare the supported RunaDB Wire Protocol versions and Runa Flow
capabilities. Compatibility is verified by the `RunaDB Client version x RunaDB Server version`
contract tests; it does not depend on matching version numbers or a shared codebase.

This repository co-locates RunaDB Server and RunaDB Client under `src/` and
`clint/` respectively. They communicate through RunaDB Wire Protocol v2; the
removed PostgreSQL adapter and SQL endpoint are not supported compatibility
surfaces.

See [ADR-0010](adr/0010-client-server-product-boundary.md) for the complete decision.
