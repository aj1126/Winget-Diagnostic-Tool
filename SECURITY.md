# Security Policy

## Supported Versions

We actively monitor and maintain the security integrity of the `winget-diagnostic-tool`. The table below outlines which release branches currently receive security patches:

| Version | Supported | Notes |
| :--- | :---: | :--- |
| 1.1.x | ✅ Yes | Current stable release branch. |
| 1.0.x | ❌ No | Legacy branch. Please upgrade to 1.1.x or higher. |
| < 1.0.0 | ❌ No | Alpha/Beta releases; completely unsupported. |

---

## Reporting a Vulnerability

> ⚠️ **Important:** Do not open a public GitHub issue for security vulnerabilities or exploits. 

If you discover a security vulnerability within this diagnostic tool (e.g., privilege escalation vectors, insecure script execution pathing, or sanitization bypasses), please report it via one of the following methods:

1. **GitHub Security Advisory**: Navigate to the **Security** tab of this repository, click **Vulnerabilities**, and select **Report a vulnerability** to submit a private draft.
2. **Direct Contact**: [Insert a secure contact method or email if preferred, e.g., security@ajukesproduction.com]

### Our Triage Commitment
* **Acknowledgment**: We aim to acknowledge your submission within **48 hours**.
* **Status Updates**: You will receive progress tracking updates at least once every **7 days** during the remediation cycle.
* **Coordinated Disclosure**: We strictly adhere to a **90-day** coordinated disclosure timeline. We ask that you do not publish details of the vulnerability until a patch has been fully vetted and merged.

---

## Repository Governance & Supply Chain Security

To protect our downstream users and ensure deterministic, tamper-proof builds, the `winget-diagnostic-tool` ecosystem enforces a strict zero-trust merge pipeline:

### 1. Hardened Branch Protections
* **Immutable History**: Force-pushes (`git push --force`) and branch deletions are completely blocked on the `main` branch. 
* **Mandatory PR Gates**: Direct pushes to `main` are restricted. All code integrations require a formal Pull Request with at least **1 linear approval** from an authorized maintainer.
* **Conversation Resolution**: Merging is programmatically blocked until every single architectural review, query, and thread is explicitly marked as **completely resolved**.

### 2. Automated Static Code Analysis (CI Gates)
Every single commit and Pull Request triggers our automated GitHub Actions engine. The following status checks are bound as non-skippable, blocking nodes in our integration pipeline:
* **Linting (`lint.yml`)**: Validates script health and adherence to project styling standards.
* **Static Analysis (`release.yml`)**: Executes comprehensive `PSScriptAnalyzer` checks to intercept dangerous PowerShell patterns, unsecure command aliases, or variable leaks prior to compilation or release.

### 3. Release Immutability
All generated binaries, execution assets, and downstream artifacts are locked via release immutability rulesets to eliminate the risk of mid-stream supply chain injections or artifact substitution.
