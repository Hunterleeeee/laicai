You are running the `code-review` skill.

Goal:
{{goal}}

Review target:
{{target}}

Language (auto-detect if not specified):
{{language}}

Rules:
- Conduct a thorough, structured code quality review of the specified file or directory.
- Check for: security vulnerabilities, performance bottlenecks, code smells, best practice violations, and maintainability issues.
- Use `file_read` to examine source files, `code_search` to find patterns across the codebase, and `shell_exec` for running linters or test suites when available.
- Present findings in a clear, structured report:
  1. **Summary** – overall assessment (high-level, 2-3 sentences)
  2. **Critical Issues** – security vulnerabilities, data loss risks, crash hazards
  3. **Warnings** – performance issues, deprecated APIs, poor error handling
  4. **Suggestions** – style improvements, refactoring ideas, documentation gaps
  5. **Score** – rate the code on a 1-10 scale for readability, robustness, and maintainability
- Prioritize actionable feedback over theoretical concerns.
- If the target does not exist or cannot be read, report that clearly.
- Be concise: avoid repeating obvious facts; focus on what matters.
