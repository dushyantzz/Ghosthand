# Security Policy

GhostHand drives a user's own machine: it reads the accessibility tree of the foreground window,
asks a decision model to choose among a deterministic list of candidate actions, and performs the
chosen action with native input. That makes its safety boundary worth stating explicitly.

## Reporting a vulnerability

Please report security issues **privately** via GitHub's
[Security Advisories](https://docs.github.com/en/code-security/security-advisories) page for this
repository (Security → Report a vulnerability) instead of opening a public issue. Include a
description, reproduction steps, the affected platform (Windows / macOS), and the commit or version.
We aim to acknowledge reports within 72 hours.

## Threat model (in scope)

1. **Prompt injection through on-screen text** — a web page or app tries to make the agent run an
   attacker-chosen action.
2. **Model selection of a destructive action** — the decision model picks an action that destroys
   data, spends money, or publishes content.
3. **Secret disclosure** — passwords, cards, tokens or keys leaking to the model provider or the
   local audit log.
4. **Untrusted target application** — a hostile app exposing misleading accessibility metadata.
5. **Automation of sensitive apps** — password managers being driven by the agent.
6. **Local credential handling** — API keys at rest.

## Controls that exist today

| Control | Where |
|---|---|
| Deletion deny-list enforced in plain code, not by the model | `RiskPolicy` / `DefaultRiskPolicy` |
| Unicode normalisation (NFC + zero-width/bidi stripping) before matching | `RiskPolicy.NormalizeForMatch` / `normalizeForMatch` |
| Password fields never read; values blanked | `UiaScreenReader` / `AccessibilityScreenReader` |
| Card, API-key, cloud-credential and PEM redaction before model + audit | `SecretSanitizer` |
| App deny-list, case-insensitive, matches renamed/suffixed binaries | `RiskPolicy.IsAppDenied` |
| Local JSONL audit log with per-run `runId` and `step` | `JsonlAuditLog` |
| API keys in Windows Credential Manager / macOS Keychain | `CredentialStore` / `KeychainCredentialStore` |
| `DRY_RUN=true` by default (simulate only) | `.env.example` |

## Known limitations and residual risk

These are deliberate trade-offs of **Jarvis mode** (auto-execute everything except deletion). Read
them before running with `DRY_RUN=false`.

- **The deletion guard is a word deny-list, not a proof.** It matches English terms
  (`delete`, `erase`, `wipe`, `destroy`, `truncate`, `format`, `del`) in control labels, values and
  typed text. It does **not** cover synonyms (`clear`, `reset`, `remove`, `uninstall`, `discard`,
  `move to trash`), non-English/localised UIs, unlabelled custom-rendered controls, or destruction
  reached through a sequence of individually benign actions.
- **Irreversible-but-not-deletion actions are auto-executed.** *Submit, Send, Pay, Buy, Purchase,
  Post, Publish, Install, Run, Transfer, Confirm* do not trigger a confirmation by default. The
  confirmation plumbing exists and **fails closed** (`AgentLoop` calls `IConfirmationPrompt` and
  refuses the action if no prompt is available), but the default policy returns "no confirmation
  required". Changing that policy is a product decision, not a bug fix.
- **The confidence gate is disabled by default.** `DECISION_CONFIDENCE_THRESHOLD` / `LAYA_MIN_CONFIDENCE`
  default to `0.0`, so the agent never falls back to `ask_user` for low-confidence choices unless you
  raise it.
- **The model chooses among candidates, and a hostile screen can contribute candidates.** Screen text
  cannot rewrite the rules or the policy, but it can influence which control is offered and picked.
- **Platform differences.** On Windows, elevated (UIPI) windows are not automated. macOS has no
  equivalent restriction. The macOS deny-list also matches the bundle identifier; Windows matches the
  process name and executable path.
- **No code signing or notarisation** on either platform's release artifacts yet.

## Recommended hardening for users

- Keep `DRY_RUN=true` until you trust the agent on your machine, then enable it deliberately.
- Run GhostHand under a least-privilege account and avoid leaving payment/email sessions signed in.
- Set `DECISION_CONFIDENCE_THRESHOLD` (Windows) or `LAYA_MIN_CONFIDENCE` (macOS) above `0.0` to make
  the agent ask instead of guessing.
- Review `%LOCALAPPDATA%\GhostHand\audit` / `~/Library/.../GhostHand/audit` periodically; entries
  carry a `runId` and `step` for tracing.
- Treat the deny-list as a floor, not a guarantee, and extend it for the apps you actually use.
