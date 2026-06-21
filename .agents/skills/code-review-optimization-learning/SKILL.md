---
name: code-review-optimization-learning
description: Guidelines and procedures for conducting code reviews, identifying performance and structural optimizations, and documenting discovered patterns as reusable skills.
---

# Code Review & Optimization Learning Guidelines

Use this skill when performing code reviews or auditing completed implementation tasks. This guide details how to evaluate code quality, verify sandbox/security boundaries, identify structural optimizations, and systematically extract lessons learned into reusable codebase skills.

---

## 1. The Code Review Process

When reviewing code, analyze the codebase across four critical dimensions:

### A. Correctness & Robustness
- **Edge Cases**: Are empty, null, or invalid inputs handled gracefully?
- **Resource Lifecycle**: Are external resources (handles, registry keys, runspaces) explicitly closed or disposed (e.g., using `finally` blocks or `.Close()` / `.Dispose()`)?
- **Error Handling**: Are catch blocks logging or handling errors appropriately rather than silencing them?

### B. Compatibility & Environment Hygiene
- **Cross-Version Support**: If using PowerShell, does the code run seamlessly on both Windows PowerShell 5.1 and PowerShell Core 7+? Avoid cmdlets/parameters that only exist in one version.
- **Scope Leakage**: Ensure scripts running in dry-run, mock, or custom runspace modes do not leak preferences (like `$WhatIfPreference`, `$ErrorActionPreference`, or global variables) back to the parent session.

### C. Compliance & Style
- **Linting**: Ensure 100% compliance with static analysis tools (e.g., `PSScriptAnalyzer`). Common rules to check:
  - `PSUseUsingScopeModifierInNewRunspaces`: Make sure variables from the parent session are accessed via `$using:varName` in new runspaces.
  - `PSAvoidUsingWriteHost`: Use `Write-Output`, `Write-Verbose`, or custom loggers instead.
  - `PSAvoidEmptyCatchBlock`: Catch blocks must contain logging, error handling, or an explicit comment justifying why the error is ignored.
  - `PSAvoidAssignmentToAutomaticVariable`: Do not assign to built-in automatic variables (such as `$PSScriptRoot`, `$ErrorActionPreference`, or `$args`). Instead, assign to custom local variables (e.g., `$ScriptDir = $PSScriptRoot`) to prevent script execution warnings or runtime failures.

### D. Sandbox & Mock Integrity
- **Mock Overrides**: Validate that .NET type mocking is clean. Direct calls to fully qualified classes (like `[System.IO.File]`) bypass type accelerators; ensure dynamic type accelerators (`[File]`, `[Registry]`) are registered and used.
- **Path Normalization**: Verify that assertions on paths are robust to dynamic temporary directory changes. Normalizing paths (e.g., mapping absolute temporary paths to relative ones) prevents test fragility.
- **Environment Isolation**: Confirm that environment variables (like `$env:LOCALAPPDATA` or `$env:USERPROFILE`) are isolated when invoking mock sub-processes.

---

## 2. Learning & Extracting Optimizations

A key goal of this process is to prevent redundant debugging. When you discover an elegant solution or debug a tricky environmental issue, document it.

### Identify Learning Candidates:
Ask yourself:
1. *Did I spend more than 15 minutes debugging a specific language quirk, runtime error, or environment issue?*
2. *Is there a clean architectural pattern that resolves this elegantly (e.g., registering local type accelerators to override native .NET classes)?*
3. *Could another developer or agent run into this exact issue on a related task?*

If the answer is **yes**, create a new skill or add to an existing skill in the customization roots.

---

## 3. How to Create/Update a Custom Skill

To package a newly learned optimization pattern:

1. **Location**: Place the skill in the workspace customizations directory:
   - `.agents/skills/<skill-name>/SKILL.md`
2. **Frontmatter**: Add YAML frontmatter to the top of `SKILL.md` for tool matching:
   ```yaml
   ---
   name: <skill-name>
   description: <short, high-density explanation of when to trigger this skill>
   ---
   ```
3. **Body Structure**:
   - **Context**: Briefly describe the problem (why it happens).
   - **Recommended Pattern**: Provide a clean, copy-pasteable code sample showing the optimized pattern.
   - **Verification Checklist**: A concise markdown checklist to guide reviews of this pattern.
