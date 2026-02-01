Prompt:
Add minimal documentation and Makefile to support repo workflows.

Goal:
Provide basic README files and a Makefile that integrates with root tooling.

Task BreakDown:
1. Add libs/hive/README.md describing the package, the umbrella product, and modules.
2. Add module README stubs (optional if in scope) that name each module.
3. Add libs/hive/Makefile with make test, make lint, make format.
4. make lint/format should be non-blocking if tools are missing (print instructions and exit 0).
