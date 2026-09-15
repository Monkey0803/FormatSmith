# Security Policy

## What this app does with your files

FormatSmith converts files entirely on your Mac. It has no networking code, does not phone home, and
does not upload anything. The only reason it might start another process is to call an external
converter you have installed yourself (LibreOffice or pandoc, for document input) — and it will only
ever do so on files you explicitly added to the queue.

## Supported versions

Only the latest release is supported with security fixes.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Instead, use GitHub's private
vulnerability reporting: go to the repository's **Security** tab → **Report a vulnerability**.

Useful reports include:

- What the vulnerability allows an attacker to do
- The steps to reproduce it, ideally with a minimal input file
- The macOS and FormatSmith versions you tested

You can expect an initial response within a few days. Please allow time for a fix to be released
before disclosing the issue publicly.

## Things that are not vulnerabilities

- macOS warning on first launch because the build is not notarized. That is expected; see the README.
- A malformed file causing that one conversion to fail with an error message. Robustness bugs are
  still worth reporting through a normal issue — but if the app crashes, or a crafted file causes
  writes outside the chosen output folder, treat it as a security issue and report it privately.
