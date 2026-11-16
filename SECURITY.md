# Security Policy (`ATProtoDrive`)

## Reporting a Vulnerability

**Do not open a public GitHub issue or pull request for security vulnerabilities.**

1. **GitHub Private Vulnerability Reporting (Preferred):** Once this repository is public, report privately at `https://github.com/joshlacal/ATProtoDrive/security/advisories/new`.
2. **Email Fallback:** Email **`security@catbird.blue`** with the repository name, commit SHA, the affected component (for example OAuth sign-in, DID/PDS resolution, repository or Space archive verification, blob download), and minimal reproduction steps.

## Scope

ATProtoDrive is a macOS client. Reports about its handling of OAuth sessions and tokens, DID document and PDS resolution, repository CAR and Space archive verification, Space credentials, and files written to disk are in scope. Vulnerabilities in the `Petrel` or `Swan` dependencies should be reported to those repositories, though a report sent here will be forwarded.

## Coordinated Disclosure Policy

- **Acknowledgement:** Within 48 hours.
- **Triage:** Within 5 business days.
- **Coordinated Embargo:** Up to 90 days for authentication, credential-handling or verification vulnerabilities, so that users can update before proof-of-concept details are published.

## Licensing

Dual-licensed under `MIT OR Apache-2.0` (`LICENSE-MIT` and `LICENSE-APACHE`), at your option.
