# Contributing

Thank you for your interest in contributing to **NetSkein!**

This project is engineered to deliver a high-performance, compile-time safe, and data-race-free asynchronous HTTP client for Swift 6.

## Local Development Setup

To maintain strict code quality, uniformity, and safety boundaries across all platforms, we enforce an automated development workflow.

NetSkein utilizes a declarative environment manager called **[mise][mise-repo]** to automatically provision and synchronize the entire development toolchain, compilers, and local code-validation loops.
This ensures a seamless, identical setup across all contributor devices without manual operating system configuration.

Please follow this guide to set up your local workspace environment.

### 1. Prerequisites

Ensure you have the required global environment manager installed on your machine:

- **macOS or Linux**: `curl https://mise.run | sh`
- **Windows**: `winget install jdx.mise`

> [!NOTE]
> NetSkein relies on the official Swift Toolchain (Swift 6.2+).
> On macOS, make sure your active Xcode or Command Line Tools version supports Swift 6.2 (Xcode 26 or later).

### 2. Initialize the Project Ecosystem

Navigate to the project root directory and run our unified initialization routine:

```bash
# Trust the local configuration file to unlock toolchain tasks execution safely
mise trust

# Run the automated project bootstrap task
mise run setup
```

**What this command does behind the scenes:**

- Automatically downloads and encapsulates all required development utilities, code formatters, and linters into an isolated, local project scope.
- Securely registers and activates automated code guardrails straight into your local Git workflow repository layout.

## How to Open an Issue

NetSkein utilizes structured GitHub templates to manage tasks and track feedback efficiently.
When opening a new issue, please select the appropriate template:

- **Bug Report**: If you encounter an unexpected behavior, ensure you provide the exact commit hash, a Minimal Reproducible Example (MRE), and your environment details (`swift --version`).
- **Feature Request**: Propose new ideas, enhancements, or architectural design changes for NetSkein.
- **Documentation Update**: Report typos, missing instructions, or suggest clarity improvements to our existing markdown docs.

_**Note:** For general questions, setup support, or architecture discussions, please use [GitHub Discussions][discussions] instead of opening an issue._

## Writing a Patch

NetSkein follows a [Trunk-Based Development][tbd] workflow.
All short-lived feature branches must branch off and merge directly back into the core production trunk (`main`).

A good NetSkein patch should be:

1. **Concise**: Contain as few changes as safely needed to achieve the desired end result.
2. **Tested**: Ensure that any newly provided unit tests accurately assert the regression or new feature boundaries.
3. **Documented**: Accompany new public types, functions and properties with doc comments, as described in [Writing Documentation](#writing-documentation).

### Step-by-Step Integration Cascade

1. **Create a Short-Lived Feature Branch**: Always branch off directly from the `main` branch (e.g., `git checkout -b feature/your-awesome-upgrade`). Keep your branches small, modular, and short-lived.
2. **Write Clean, Highly-Covered Code**: Ensure your changes are backed up by descriptive unit tests under `Tests/NetSkeinTests`. We expect all incoming code modifications to maintain a high test density.
3. **Commit Your Work**: Simply execute your standard version control commit sequence. If the background guardrails adjust formatting automatically, stage the newly formatted lines and proceed. If safety violations occur, resolve the source warnings manually.
4. **CI Validation & Code Coverage Gate**: Every opened PR triggers our parallel **GitHub Actions Continuous Integration** grid. The runner will validate style layouts, compile the targets, and execute the test suite.
   - **Absolute Coverage Threshold**: Your PR will be blocked from merging if the automated test coverage falls below the **minimal required project baseline**. Always ensure your new logic is thoroughly covered by tests before pushing.

## Writing Documentation

NetSkein's API reference is built with DocC from `///` comments and the catalogs in `Sources/*/*.docc`.
Run `make docs` to build it and `make docs-preview` to browse it locally.
CI builds it on every pull request and fails on any warning, such as a link to a symbol that no longer exists.

Every public declaration needs a doc comment:

- **Summary**: one sentence saying what it does, followed by details in their own paragraphs if needed.
- **Defaults**: write them as `(default: Value)`, in human units rather than code, such as `(default: 30 seconds)` or `(default: 10 MiB)`. Link a symbol when the default is one, such as `(default: ``RetryPolicy/disabled``)`. State it once: in the parameter line for a parameter's default, otherwise in the summary. Explain what `nil` means separately, such as "`nil` removes the limit".
- **Parameters**: every function and initializer that takes arguments documents each one, with `- Parameter name:` for one argument or `- Parameters:` for several.
- **Returns**: every function that returns a value has `- Returns:`. Fluent methods say what the copy holds, such as "A copy of the request with the header set."
- **Throws**: every throwing function has `- Throws:`, naming the ``NetSkeinError/Kind`` thrown and when.
- **Links**: refer to other symbols with double backticks, such as ` ``NetSkeinRequest/send()`` `, so DocC checks that they exist.

Non-public declarations need a comment only when their name and type leave something out, such as what `nil` means, a unit, an invariant, or why it exists:

```swift
/// `nil` uses the client's policy.
private var retryPolicy: RetryPolicy?
```

Skip comments that only repeat the name, such as `/// The URL.` above `private var url: String`.

Protocol requirements such as `==`, `hash(into:)` and `init(stringLiteral:)` may skip the parameter sections, since DocC shows the protocol's documentation.

```swift
/// Sets the header `name` to `value`, replacing any value it had.
///
/// - Parameters:
///   - name: The header name, such as `Authorization`. Names are case-insensitive.
///   - value: The header value.
/// - Returns: A copy of the request with the header set.
public func header(_ name: String, _ value: String) -> Self
```

## Using AI Tools

You may use AI tools to help write your contribution, but you are its author and must be able to explain every change you submit.
Commits and pull requests must not credit an AI tool as a co-author (for example, `Co-Authored-By: Claude`); a CI check rejects them.

Please read the full [AI Policy](AI_POLICY.md) before opening a pull request.

## Legal

By contributing to NetSkein, you agree that your contributions will be dual-licensed under the terms of both the **Apache License Version 2.0** and the **MIT License**.

[mise-repo]: https://github.com/jdx/mise
[discussions]: https://github.com/orthogonest/netskein/discussions
[tbd]: https://trunkbaseddevelopment.com
