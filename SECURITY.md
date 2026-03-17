# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability in Hive, please report it responsibly:

1. **Do not open a public issue**
2. Email the maintainer directly at [security vulnerability reporting email]
3. Include:
   - Description of the vulnerability
   - Steps to reproduce (if applicable)
   - Potential impact
   - Suggested fix (if any)

You can expect:
- Acknowledgment within 48 hours
- Regular updates on the progress
- Credit in the release notes (if desired) after the fix is released

## Security Considerations

When using Hive in production:

### Checkpoint Security

- Checkpoint data may contain sensitive information
- Use encrypted storage for checkpoint persistence
- Implement appropriate access controls for checkpoint stores

### LLM Integration

- Review and validate all tool definitions before exposing to LLMs
- Implement rate limiting for LLM API calls
- Monitor token usage and associated costs

### Input Validation

- Validate all inputs to graph nodes
- Sanitize data before storing in channels
- Be cautious with dynamic content in LLM prompts

## Best Practices

1. **Least Privilege**: Run Hive with minimal necessary permissions
2. **Audit Logging**: Enable logging for security-relevant events
3. **Resource Limits**: Set appropriate `maxSteps` limits to prevent infinite loops
4. **Error Handling**: Don't expose internal error details to end users
