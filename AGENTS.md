# AGENTS.md

## iOS Development

This is a modern SwiftUI project built with the iOS 27 SDK.

### Tool Priority

For all Apple-platform development, prefer these plugins:

1. **Xcode**
   - Primary source of truth for Apple APIs and platform behavior.
   - Use its official Xcode 27 skills and MCP tools for:
     - Swift / SwiftUI guidance
     - iOS 27 APIs
     - Apple documentation
     - build and diagnostics
     - tests
     - previews
     - device and Simulator interaction
   - Verify unfamiliar or newly introduced APIs through Xcode instead of guessing.

2. **Build iOS Apps**
   - Use for implementation-oriented workflows, especially:
     - SwiftUI UI implementation and refactoring
     - Simulator interaction
     - debugging
     - performance profiling
     - memory investigation
     - visual validation

Use only the relevant skills/tools for the task. Do not load every skill unnecessarily.

### Development Principles

- Prefer native SwiftUI and current Apple APIs.
- Follow modern iOS 27 design and platform conventions.
- Prefer Apple frameworks over unnecessary third-party dependencies.
- Preserve the existing deployment target unless explicitly asked to change it.
- Use accessibility, Dynamic Type, Dark Mode, and Reduce Motion appropriately.
- Use Liquid Glass only where it improves hierarchy or interaction; avoid excessive decorative glass, cards, gradients, and shadows.
- Do not invent API names or behavior.

## Git & Commit Rules

- Do not create a commit unless explicitly requested.
- Before committing, review `git status` and the final diff.
- Commit only files related to the requested task.
- Never include unrelated user changes in a commit.
- Prefer small, atomic commits with one clear purpose.
- Do not commit secrets, credentials, local configuration, build artifacts, or temporary files.

### Commit Messages

Use Conventional Commits:

```text
<type>(<scope>): <summary>
```

### Validation

For meaningful code or UI changes:

1. Implement the change.
2. Build using Xcode.
3. Resolve introduced errors and warnings.
4. Run relevant tests when applicable.
5. For UI changes, inspect the result with Preview or Simulator when practical.
6. Fix visible layout or interaction issues before considering the task complete.

When Xcode and general model knowledge disagree, prefer verified Xcode / Apple SDK behavior.
