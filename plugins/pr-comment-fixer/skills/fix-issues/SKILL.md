---
name: fix-issues
description: Automatically read GitHub pull request review comments and apply fixes to address feedback. Use this skill when the user asks to review and fix PR comments, address PR feedback, or resolve review suggestions. Triggers include phrases like "fix PR comments", "address PR feedback", "review PR #123 and fix comments", or "resolve review feedback". Handles code quality issues, bug fixes, logic improvements, and all types of review suggestions.
---

# PR Comment Fixer

Automatically processes GitHub pull request review comments and applies code fixes to address reviewer feedback.

## Workflow

Follow this workflow when the user requests PR comment fixes:

### 1. Extract PR Information

Parse the PR number from the user's request. Accept formats like:
- "PR #1234"
- "pull request 1234"
- "#1234"
- Just the number "1234"

### 2. Fetch PR Details

Use GitHub CLI to get PR information:

```bash
gh pr view <PR_NUMBER> --json number,title,headRefName,repository
```

Extract:
- `headRefName`: The PR branch name
- `repository`: Owner and repo name

### 3. Ensure Repository Access

Check if running locally or remotely:

```bash
git rev-parse --git-dir 2>/dev/null
```

If this fails (not in a git repository):
- Clone the repository: `gh repo clone <OWNER>/<REPO>`
- Change to repository directory

If successful (already in repository):
- Verify it's the correct repository
- Continue with existing local clone

### 4. Checkout PR Branch

Switch to the PR branch:

```bash
git fetch origin
git checkout <BRANCH_NAME>
git pull origin <BRANCH_NAME>
```

### 5. Fetch All PR Comments

Retrieve review comments using GitHub CLI:

```bash
gh pr view <PR_NUMBER> --json reviews,comments --jq '.reviews[].comments[], .comments[]'
```

Parse the JSON output to extract:
- Comment body/text
- File path (if applicable)
- Line number or diff position
- Author
- Whether it's resolved or pending

### 6. Evaluate Comment Relevance

For each comment, determine if it's actionable:

**Actionable comments** (should be fixed):
- Requests for code changes (naming, formatting, refactoring)
- Bug reports or logic errors
- Suggestions for improvements
- Security or performance concerns
- Missing error handling
- Code quality issues

**Non-actionable comments** (skip):
- General discussion or questions already answered
- Comments marked as resolved
- Informational comments with no change request
- Compliments or approvals

When in doubt, err on the side of treating comments as actionable.

### 7. Apply Fixes

For each actionable comment:

1. **Locate the code**: Read the mentioned file and find the relevant section
2. **Understand context**: Review surrounding code and the PR diff to understand the change
3. **Determine fix**: Based on the comment, determine the appropriate code change
4. **Apply fix**: Modify the file using str_replace or edit_file tools
5. **Verify**: Ensure the fix is syntactically correct and addresses the comment

Work through all comments systematically before committing.

### 8. Create Commit

After all fixes are applied, create a single commit:

```bash
git add -A
git commit -m "Address PR review comments: <SUMMARY>"
```

Where `<SUMMARY>` is a brief description of what was changed, such as:
- "Fix variable naming and add error handling"
- "Refactor method structure and improve readability"
- "Address code quality feedback"

### 9. Push Changes

Push the commit to the PR branch:

```bash
git push origin <BRANCH_NAME>
```

### 10. Report Results

Provide the user with:
- Number of comments processed
- Number of fixes applied
- List of files modified
- Commit SHA
- Any comments that couldn't be addressed (with reasons)

## Error Handling

Handle common errors gracefully:

- **PR not found**: Verify the PR number and repository
- **Branch conflicts**: Inform user and suggest manual resolution
- **Permission issues**: Check GitHub authentication with `gh auth status`
- **Ambiguous comments**: Ask user for clarification on specific comments
- **Code conflicts**: If a fix would create merge conflicts, note it in the report

## Best Practices

- Always read the full file context before making changes
- Preserve existing code style and formatting
- If a comment is unclear, ask the user for clarification before fixing
- Group related changes logically
- Test syntax by attempting to parse modified code when possible
- Keep changes minimal and focused on addressing the specific feedback

## Good to know
- If you cannot find gh.exe, try path C:\Program Files\GitHub CLI