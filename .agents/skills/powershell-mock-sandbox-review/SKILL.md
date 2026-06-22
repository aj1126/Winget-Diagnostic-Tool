---
name: powershell-mock-sandbox-review
description: Reference guidelines and a review checklist for auditing PowerShell sandbox isolation, .NET type mocking via accelerators, and dot-sourced test harness issues.
---

# PowerShell Mocking & Sandbox Review Guidelines

Use this skill to audit and review PowerShell scripts and test runners that use C# mock classes, sandbox processes, or type accelerators. It contains structural patterns discovered during the debugging of cross-PowerShell (v5.1/v7) test suites.

## 1. Type Accelerator Redirection Pattern
Fully qualified .NET class names (e.g., `[System.IO.File]` or `[Microsoft.Win32.Registry]`) bypass custom type accelerator overrides because PowerShell resolves them directly via CLR type lookups.

### Recommended Implementation:
1. **In the Script Under Test**:
   - Register the short type accelerator dynamically at the top of the script if not already present:
     ```powershell
     $taInstance = [psobject].Assembly.GetType("System.Management.Automation.TypeAccelerators")
     if (-not $taInstance::Get.ContainsKey("File")) {
         $taInstance::Add("File", [System.IO.File])
     }
     ```
   - Replace all occurrences of `[System.IO.File]` with `[File]` throughout the script.
2. **In the Test Runner**:
   - Register the short name to point to your mock class:
     ```powershell
     $ta::Add("File", [MockFile])
     ```

---

## 2. Dot-Sourcing Scope & `$WhatIfPreference` Leakage
Dot-sourcing a script under test running with `-DryRun` or `-WhatIf` sets `$WhatIfPreference = $true`. Because dot-sourcing runs in the caller's session scope, this flag persists in the test runner session after execution.
Any file writes (such as generating `final_state.json` via `Out-File`) inside the test runner's `finally` block will be silently simulated as "What If" operations and won't write to disk.

### Review Checklist:
- [ ] Ensure that `$WhatIfPreference = $false` is explicitly set at the start of the `finally` block of the test runner:
  ```powershell
  try {
      . .\ScriptToTest.ps1 -DryRun
  } finally {
      $WhatIfPreference = $false
      $finalState | ConvertTo-Json | Out-File "final_state.json"
  }
  ```

---

## 3. Path Normalization in Mocks
Asserting against command execution strings with file paths often fails when run in sandboxes due to temporary host-specific absolute paths.

### Review Checklist:
- [ ] If a test assertion checks for a string like `"Invoke-WebRequest: ... -> Temp\Output.msix"`, make sure the mock cmdlet normalizes absolute temporary paths back to relative ones in `CalledCmdlets`:
  ```powershell
  $normalizedOutFile = $OutFile -replace '[A-Z]:\\.*\\Temp\\', 'Temp\'
  $global:CalledCmdlets.Add("Invoke-WebRequest: $Uri -> $normalizedOutFile")
  ```

---

## 4. Administrative Status & claims Mocking
When testing code that checks user elevation via `[System.Security.Principal.WindowsIdentity]::GetCurrent()`, the script under test may attempt to query `.Claims` for the admin SID (`S-1-5-32-544`).

### Review Checklist:
- [ ] Ensure that `MockWindowsIdentity` exposes a `Claims` property populated with a mock admin claim when the elevation environment variable is active:
  ```csharp
  public class MockClaim {
      public string Value { get; set; }
      public MockClaim(string val) { Value = val; }
  }
  public class MockWindowsIdentity {
      public List<MockClaim> Claims { get; set; }
      public MockWindowsIdentity() {
          Claims = new List<MockClaim>();
          if (Environment.GetEnvironmentVariable("MOCK_IS_ADMIN") == "true") {
              Claims.Add(new MockClaim("S-1-5-32-544"));
          }
      }
  }
  ```
- [ ] **Elevated Registry Redirection**: When mocking elevated registry modifications, redirect HKEY_CURRENT_USER (HKCU) queries to the appropriate mocked user hive (e.g., `HKEY_USERS\<SID>\Environment`) because Windows maps user environments to HKEY_USERS under elevation.

---

## 5. Fully Qualified Type Mocking via Class Reference Variables
When code under test calls fully qualified .NET static methods directly (e.g., `[System.Security.Principal.WindowsIdentity]::GetCurrent()`), it bypasses short type accelerators like `[WindowsIdentity]`. Replacing all instances with a short name might be verbose or prone to regression.

### Recommended Implementation:
1. **In the Script/Module Under Test**:
   Declare script-scoped class reference variables at the top of the file/module helper:
   ```powershell
   $script:WindowsIdentityClass = [System.Security.Principal.WindowsIdentity]
   $script:RegistryClass = [Microsoft.Win32.Registry]

   if ($env:IsTestRunner) {
       $script:WindowsIdentityClass = [MockWindowsIdentity]
       $script:RegistryClass = [MockRegistry]
   }
   ```
2. **Throughout the Script**:
   Invoke static methods/properties through the reference variable:
   ```powershell
   $identity = $script:WindowsIdentityClass::GetCurrent()
   $key = $script:RegistryClass::CurrentUser.OpenSubKey("Environment")
   ```

### Review Checklist:
- [ ] Audit the codebase for fully qualified type names (`[System.*]`) used to invoke static methods.
- [ ] Ensure they are mapped to `$script:<Name>Class` reference variables if they need to be intercepted in E2E tests.

