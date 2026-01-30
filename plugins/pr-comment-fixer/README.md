# PR Comment Fixer

Automatically processes GitHub pull request review comments and applies code fixes to address reviewer feedback.

## Features

- **Extract PR Information**: Parses PR numbers from user requests.
- **Fetch PR Details**: Uses GitHub CLI to get PR metadata (branch, repo).
- **Checkout PR Branch**: automatically handles git operations to switch to the correct branch.
- **Fetch Comments**: Retrieves review comments from the PR.
- **Evaluate Relevance**: Filters comments to identify actionable items (bugs, style fixes) vs non-actionable (discussions).
- **Apply Fixes**: Locates code and applies fixes based on the comment context.
- **Commit & Push**: consolidated changes into a single commit and pushes back to the PR branch.
- **Report**: Provides a summary of processed comments and applied fixes.

## Skills

This plugin contains the following skill:

- **fix-issues**: The core logic for reading comments and applying fixes.

## Usage

This plugin is designed to be used when you ask the agent to "fix PR comments", "address PR feedback", or similar requests. It requires the GitHub CLI (`gh`) to be installed and authenticated.
