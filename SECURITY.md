# Security Policy

## Reporting a vulnerability

Please report security issues privately through the repository's GitHub
Security Advisories if that feature is enabled. If it is not available, open
an issue with the minimum details needed to request a private follow-up and do
not include sensitive data or an exploit that affects other users.

Include the affected version, Omarchy/Quickshell version, reproduction steps,
and the impact. Please allow time for a fix before public disclosure.

## Security model

This plugin runs unsandboxed inside `omarchy-shell`, as required by the
Omarchy plugin architecture. It reads workspace/window state and intentionally
renders live window contents. It does not make network requests, write
screenshot files, install packages, or use privilege escalation.
