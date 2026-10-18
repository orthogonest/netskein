# Contributing

Thank you for your interest in contributing to **NetSkein!**
This project is engineered to deliver a high-performance, compile-time safe, and data-race-free asynchronous HTTP client for Swift 6.

## Local Development Setup

To maintain strict code quality, uniformity, and safety boundaries across all platforms, we enforce an automated development workflow.

NetSkein utilizes a declarative environment manager called **[mise](https://github.com/jdx/mise)** to automatically provision and synchronize the entire development toolchain, compilers, and local code-validation loops.
This ensures a seamless, identical setup across all contributor devices without manual operating system configuration.

Please follow this guide to set up your local workspace environment.

### 1. Prerequisites

Ensure you have the required global environment manager installed on your machine:

- **macOS or Linux**: `curl https://mise.run | sh`
- **Windows**: `winget install jdx.mise`

> [!NOTE]
> NetSkein relies on the official Swift Toolchain (Swift 6.0+).
> On macOS, make sure your active Xcode or Command Line Tools version supports Swift 6.

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

_Note: For general questions, setup support, or architecture discussions, please use [GitHub Discussions](https://github.com/orthogonest/netskein/discussions) instead of opening an issue._

## Writing a Patch

NetSkein follows a [Trunk-Based Development](https://trunkbaseddevelopment.com) workflow.
All short-lived feature branches must branch off and merge directly back into the core production trunk (`main`).

A good NetSkein patch should be:

1. **Concise**: Contain as few changes as safely needed to achieve the desired end result.
2. **Tested**: Ensure that any newly provided unit tests accurately assert the regression or new feature boundaries.
3. **Documented**: Accompany new functions, types, or public properties with clean structural API documentation (`///`).

### Step-by-Step Integration Cascade

1. **Create a Short-Lived Feature Branch**: Always branch off directly from the `main` branch (e.g., `git checkout -b feature/your-awesome-upgrade`). Keep your branches small, modular, and short-lived.
2. **Write Clean, Highly-Covered Code**: Ensure your changes are backed up by descriptive unit tests under `Tests/NetSkeinTests`. We expect all incoming code modifications to maintain a high test density.
3. **Commit Your Work**: Simply execute your standard version control commit sequence. If the background guardrails adjust formatting automatically, stage the newly formatted lines and proceed. If safety violations occur, resolve the source warnings manually.
4. **CI Validation & Code Coverage Gate**: Every opened PR triggers our parallel **GitHub Actions Continuous Integration** grid. The runner will validate style layouts, compile the targets, and execute the test suite.
   - **Absolute Coverage Threshold**: Your PR will be blocked from merging if the automated test coverage falls below the **minimal required project baseline**. Always ensure your new logic is thoroughly covered by tests before pushing.

## Legal

By contributing to NetSkein, you agree that your contributions will be dual-licensed under the terms of both the **Apache License, Version 2.0** and the **MIT License**.
