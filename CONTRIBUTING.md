# Contributing to Hive

Thank you for your interest in contributing to Hive! This document provides guidelines for contributing to the project.

## Development Setup

### Requirements

- Swift 6.2 or later
- macOS 26+ or iOS 26+ (for development)
- Xcode 16+ (optional, for IDE support)

### Building

```bash
swift build
```

### Testing

```bash
swift test
```

If you encounter intermittent test runner hangs, use the stable runner:

```bash
./scripts/swift-test-stable.sh
```

## Project Structure

```
Sources/Hive/
├── Sources/
│   ├── HiveCore/          # Zero-dependency core (schema, graph, runtime, store)
│   ├── HiveDSL/           # Result-builder workflow DSL
│   ├── HiveConduit/       # LLM adapter integration
│   ├── HiveCheckpointWax/ # Persistent checkpoint storage
│   ├── HiveRAGWax/        # Vector RAG storage
│   └── Hive/              # Umbrella module
├── Tests/                 # Test suites for each module
└── Examples/              # Example executables
```

## How to Contribute

### Reporting Issues

- Use GitHub Issues to report bugs or request features
- Include a clear description of the problem
- Provide minimal reproduction steps for bugs
- Mention your environment (OS, Swift version)

### Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass (`swift test`)
6. Commit your changes (`git commit -m 'Add amazing feature'`)
7. Push to your branch (`git push origin feature/amazing-feature`)
8. Open a Pull Request

### Code Style

- Follow Swift 6.2 best practices
- All public types must be `Sendable`
- Use Swift's strict concurrency model
- Document public APIs with DocC comments

### Testing Guidelines

- Write tests using Swift Testing (`@Test`, `#expect`)
- Use inline schemas for test isolation
- Assert exact event ordering for determinism verification
- Include checkpoint round-trip tests for resumable workflows

### Specification Compliance

Hive's runtime behavior is defined by `HIVE_SPEC.md`. When contributing:

- Implementation follows the spec — not the other way around
- Use RFC 2119 keywords (MUST/SHOULD/MAY) when referencing spec requirements
- Ensure determinism guarantees are maintained

## Commit Message Guidelines

- Use conventional commits format
- Keep the first line under 72 characters
- Reference issues when applicable

Example:
```
feat: add evictThread() API for memory management

Adds public method to release in-memory state for completed threads.
Prevents unbounded memory growth in long-running applications.

Fixes #123
```

## Questions?

- Read the [full documentation](https://christopherkarani.github.io/Hive/)
- Check the [HIVE_SPEC.md](HIVE_SPEC.md) for runtime behavior details
- Open a GitHub Discussion for questions

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
