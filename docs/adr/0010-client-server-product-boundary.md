# Pico Client and Pico Server Are Independent Products

Pico is a database product ecosystem composed of two independent products: **Pico Server** and **Pico Client**. The repository contains the server implementation and documentation; the client CLI, drivers, migration tools, and other developer tools are not server implementation modules and must not enter its runtime, storage, or release artifacts.

The products cooperate only through the versioned **Pico wire protocol**, **Pico SQL**, and public error model. They can build, release, upgrade, and roll back independently. The server is authoritative for data, transactions, durability, and recovery; the client is authoritative for local interaction, connection configuration, protocol encoding, and developer experience.

## Decision Drivers

1. Server correctness, resource usage, and recovery boundaries must not follow CLI or language-driver release schedules.
2. Clients need independent language coverage, installation, and interaction design.
3. Cross-product compatibility must be an explicit, testable protocol contract rather than an accidental result of same-repository calls.

## Considered Options

- **One product and one release artifact**: rejected because client dependencies would enter server releases and runtime.
- **Server-embedded CLI with independent drivers**: rejected because it creates two product boundaries and version rules.
- **Two independent products (adopted)**: Pico Server and Pico Client release separately, with protocol versions and support matrices maintaining compatibility.

## Consequences

- Pico Server publishes only the server process, server configuration, storage format, and server documentation.
- Pico Client publishes the CLI, drivers, SDKs, and migration tooling.
- Shared source definitions are limited to `clint/proto/`; there are no direct imports across client and server implementation code.
- Each product may have its own CI, release cadence, and version, even when hosted in one repository.
- Integration tests must exercise the public protocol boundary.

## Delivery

1. Define the versioned Pico wire protocol and Pico SQL support matrix.
2. Build the minimum Pico Client CLI and use it for end-to-end protocol tests.
3. Keep the server and client as separate build targets with no cross-boundary implementation imports.
4. Publish independent release artifacts and compatibility documentation.
