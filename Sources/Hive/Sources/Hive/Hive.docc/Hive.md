# ``Hive``

Deterministic graph runtime for Swift.

@Metadata {
    @DisplayName("Hive")
}

## Overview

The `Hive` module re-exports `HiveCore`. Use it when you want the core graph runtime API from a single package product.

Hive executes typed graphs as deterministic supersteps. Frontier nodes run concurrently, writes commit atomically, routers schedule the next frontier, and checkpoints can persist resumable runtime state.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:ConceptualOverview>
