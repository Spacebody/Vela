# Pull request

Describe the change, its scope, and the user-visible outcome.

## Feature-freeze change control

This block is required while the V1 feature freeze is active. Keep every field exactly once and replace every `REPLACE_ME` value. Use `none` when an impact is explicitly absent.

Allowed `changeClass` values: `securityFix`, `dataIntegrityFix`, `crashFix`, `reliabilityFix`, `performanceFix`, `accessibilityFix`, `localizationOrDocumentation`, `releaseEngineering`.

Allowed `severity` values: `critical`, `high`, `medium`, `low`, `informational`.

<!-- VELA-FEATURE-FREEZE-CHANGE-CONTROL-START -->
```yaml
changeClass: REPLACE_ME
issueID: REPLACE_ME
severity: REPLACE_ME
userImpact: REPLACE_ME
securityImpact: REPLACE_ME
contractImpact: REPLACE_ME
migrationImpact: REPLACE_ME
testEvidence: REPLACE_ME
releaseNoteImpact: REPLACE_ME
reviewer: REPLACE_ME
```
<!-- VELA-FEATURE-FREEZE-CHANGE-CONTROL-END -->

## Verification

- [ ] The change stays within the declared impact.
- [ ] Relevant automated tests and manual checks are listed above.
- [ ] User-facing behavior and Known Limitations are updated when needed.
- [ ] A non-`none` contract impact includes the required ADR, approvals, new RC number, and full migration/update matrix.
