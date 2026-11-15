# Security Policy

Stscp drives the system OpenSSH client and executes commands on remote hosts, so bugs in
argument handling or shell escaping can have real security impact. Reports are welcome.

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

Please **do not open a public issue**. Instead, use GitHub's private vulnerability reporting:
open the repository's **Security** tab and click **Report a vulnerability**.

Include, where possible:

- the Stscp version and macOS version;
- steps to reproduce (file or directory names, site settings — never real keys or hostnames);
- the impact you observed or expect.

You should receive an initial response within a few days. Once a fix is released, the report
can be disclosed publicly with credit to the reporter, if desired.

## Scope

In scope: shell/argument injection via file names or site settings, unintended remote or local
file modification or deletion, leakage of connection details, and similar issues in Stscp itself.

Out of scope: vulnerabilities in OpenSSH or macOS themselves, and the fact that release builds
are not notarized (this is documented).
