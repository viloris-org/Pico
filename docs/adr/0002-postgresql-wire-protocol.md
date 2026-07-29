# Adopt the PostgreSQL Frontend/Backend Protocol for the External Wire Protocol

Clients connect using the **PostgreSQL wire protocol** rather than a custom binary protocol or HTTP alone, allowing direct use of `psql`, libpq, and PostgreSQL drivers in multiple languages.

Protocol compatibility is an **access-layer** goal; it **does not imply** compatibility with the full PostgreSQL SQL dialect or behavior (see ADR-0003).

## Considered Options

- **Custom protocol + official SDK**: A smaller implementation surface, but the ecosystem would start from zero, which conflicts with the goal of broad protocol support.
- **MySQL protocol**: An equally mature driver ecosystem, but it does not match the team’s greater familiarity with the PostgreSQL toolchain.
- **PostgreSQL wire protocol (adopted)**: Provides broad tool and ORM coverage; start with the simple query protocol, then extend to extended queries, portals, and related features.

## Consequences

- Authentication, message types, error codes, and similar details should initially align with PostgreSQL conventions to reduce surprising driver behavior.
- Unsupported SQL must return clear errors, avoiding “it connects but silently returns wrong results.”
- Protocol tests use real clients (at least `psql` plus one mainstream driver) as the regression baseline, not only unit-level codec tests.
