# AI Policy

NetSkein accepts contributions written with the help of AI tools such as Claude, Copilot, Cursor, or ChatGPT.
This policy exists because review time is limited, and a pull request the author has not read costs reviewers far more than it costs the author.

The short version: **You may use AI, but you are the author, and the AI is not.**

## Rules

### 1. You must understand every change you submit

Before opening a pull request, read the full diff yourself.
You must be able to explain any line in it during review: why it is there, what it does, and why it is correct.

If a reviewer asks about a change and the answer is effectively "the AI wrote it", the pull request will be closed.

### 2. AI tools are never credited as authors

Commits and pull request descriptions must not contain trailers that credit an AI tool, for example:

```text
Co-Authored-By: Claude <noreply@anthropic.com>
Co-authored-by: Copilot <...>
```

Many AI tools add these trailers automatically when they commit on your behalf.
We treat that as a sign the code went from the tool to the repository without passing through you.
Write and review your commits yourself, and remove these trailers before pushing.

Human co-authors are welcome and should keep using `Co-authored-by` as usual.

### 3. You are responsible for provenance and licensing

All contributions are dual-licensed under the Apache License 2.0 and the MIT License (see [CONTRIBUTING.md](CONTRIBUTING.md#legal)).
By submitting, you confirm you have the right to license the code under those terms, however it was produced.
Do not submit output you have reason to believe reproduces code under an incompatible license.

### 4. AI-generated code meets the same bar as any other code

The usual requirements in [CONTRIBUTING.md](CONTRIBUTING.md) still apply: concise changes, tests that cover them, documentation for public API, and the CI coverage gate.
Tests must actually exercise the behavior they claim to cover. Generated tests that only increase coverage numbers will be rejected.

### 5. Disclosure is optional

You do not have to say whether you used AI.
If you want to mention it, for example to give reviewers context, do so in the pull request description, not in commit trailers.

### 6. Issues, discussions, and review comments

The same principles apply outside of code.
Bug reports must describe behavior you actually observed, with a reproduction you have run.
Please do not post AI-generated issues, reviews, or security reports you have not verified yourself.

## Enforcement

Pull requests that break these rules may be closed without detailed review.
Repeated low-effort submissions may result in being blocked from the repository, in line with the [Code of Conduct](CODE_OF_CONDUCT.md).

If you are unsure whether your contribution fits this policy, ask in [GitHub Discussions](https://github.com/orthogonest/netskein/discussions) before opening a pull request.
