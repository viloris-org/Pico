# Pico Product Boundary

Pico consists of two independently released products: Pico Server and Pico Client. They
cooperate only through the versioned Pico wire protocol, Pico SQL, and the public
error model; they do not share a data directory, storage implementation, or
in-process API.

| Product | Responsibilities | Owns | Not responsible for |
| --- | --- | --- | --- |
| Pico Server | Accepts connections, executes Pico SQL, commits transactions, maintains the data directory, and performs recovery | Data, catalog, transactions, WAL, durability, recovery, and server configuration | CLI, language drivers, ORMs, and interactive tools |
| Pico Client | Provides the CLI, drivers, and developer tools, and encodes user operations as the Pico wire protocol | Local interaction, connection configuration, protocol encoding/decoding, and client-side error presentation | Data directories, storage formats, transaction commit, and durability implementation |

## Compatibility

The two products are built, versioned, released, and rolled back independently. Each
version must declare the supported Pico wire-protocol versions and Pico SQL
capabilities. Compatibility is verified by the `Pico Client version x Pico Server version`
contract tests; it does not depend on matching version numbers or a shared codebase.

This repository currently contains only Pico Server. Pico Client has not yet been
established; the current `psql` connection is used solely to validate the temporary
PostgreSQL adapter and is not a commitment to support Pico Client.

See [ADR-0010](adr/0010-client-server-product-boundary.md) for the complete decision.
