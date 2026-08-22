# Engineering Principles & Standard

The standard for every software project, not aspirational, the bar. (Canonical copy lives in `~/.claude/ENGINEERING_PRINCIPLES.md` and loads into every project via `~/.claude/CLAUDE.md`; this is a mirror.)

**This is a design-time and write-time standard, not just an audit checklist.** Apply it as you plan and write new code, so code is built to this bar from the first line. Use it again to review and to run periodic audits. When you fix anything, add a regression test so it stays fixed.

For each area: ask the guiding question, then meet the concrete items.

---

## 1. Correctness & Testing
*"How do we know this works, and that a fixed bug stays fixed?"*
- Real automated tests on the core logic (validators, calculations, auth/permission gates, data transforms), not placeholder tests.
- Every bug fix ships with a regression test that fails before the fix and passes after.
- Tests run in CI and block deploy on red.
- No flags or empty suites masking zero coverage.

## 2. Simplicity & Code Quality
*"Is this the simplest thing that works, and would a new engineer understand it fast?"*
- Prefer the simplest solution that meets the need; no cleverness for its own sake.
- Small, focused functions and modules with meaningful names.
- Don't repeat yourself: shared logic lives in one place.
- Delete dead code, unused flags, and commented-out blocks; leave it cleaner than you found it.
- Consistent style enforced by lint/format, so reviews are about substance.

## 3. Performance & UX
*"When does this feel slow or annoying?"*
- Optimistic rendering: never make a user wait on a round-trip to see their own edit.
- Explicit loading, empty, and error states on every view.
- Every input and control has a visible label and a helpful tooltip.
- Instant feedback on interaction (under ~100ms); no blocking synchronous work on the request path.

## 4. Scalability
*"Does this survive 1,000 new users tomorrow? 100,000?"*
- Pagination everywhere a list can grow; never load an unbounded table into memory.
- No N+1 queries: batch or join, and add the indexes the query planner actually needs.
- API responses bounded and paginated (cursor pagination for large sets).
- Caching for hot, expensive, or cross-service reads, with sane TTLs and clear invalidation.
- Stateless app tier so it scales horizontally; no in-memory state that breaks with more than one instance.
- Connection pooling sized to the database; heavy or slow work offloaded to a queue/worker, not the request.
- Rate limiting on public and expensive endpoints.
- Load-test the paths that matter before they matter.
- Cost awareness: an inefficient query, a chatty loop, or a runaway job is both a scaling and a cost problem; measure it.

## 5. Resilience & Reliability
*"What happens when a dependency, third-party API, or the network is down?"*
- Every external call has a timeout and retries with backoff.
- Idempotency on anything that sends, charges, or writes: a retry must never double-do it.
- Graceful degradation: a partial failure shows what is available plus a clear partial state, it never white-screens the page.
- No single point of failure on a critical path; isolate a flaky dependency behind a fallback or circuit breaker.
- Fail safe, not open: on error, deny or degrade, never leak or corrupt.

## 6. Security & Data Safety
*"What would be a disaster if it leaked, or got deleted?"*
- Least privilege everywhere: scoped tokens and roles, no god-mode by default.
- Never forge, print, or log secrets; all secrets rotatable, and rotated on any exposure.
- Authorization enforced at the boundary (row-level security / server-side checks), never trusted from the client.
- Validate and sanitize all input with a schema at the edge; parameterized queries only.
- Privacy: collect the minimum personal data needed, define retention, honor consent, and never log personal data.
- Deactivate, do not hard-delete, records that own history; back up before any destructive operation.
- Test that backups actually RESTORE, not just that they run; a backup you have never restored is a hope, not a safety net.
- Schema changes via migrations, never runtime DDL.
- Append-only audit log for sensitive actions: who did what, when.

## 7. Observability
*"How would I find out if something broke at 3am, before a user tells me?"*
- Structured logs with enough context to diagnose (ids and state, not just messages).
- Errors captured and alerted to a real place, not buried in a log nobody reads.
- Health checks per service, plus automated canaries that exercise real user flows.
- Key latency and error metrics tracked; alerts are actionable, not noisy.

## 8. Accessibility & Inclusivity
*"Could someone use this on their phone, one-handed, or with bad eyesight?"*
- Responsive and mobile-usable, with real touch-target sizes.
- Fully keyboard navigable, with visible focus states.
- Sufficient color contrast; never signal with color alone.
- Labels and ARIA where they matter; sane for a screen reader.

## 9. Dependencies & Supply Chain
*"Do we trust and control everything we pull in, and is it current?"*
- Keep dependencies current and patched; no known high or critical CVEs shipping.
- Minimal and maintained: no abandoned or unnecessary packages; justify each new one.
- Lockfiles committed; installs are reproducible.
- Verify what actually runs in production; watch for supply-chain risk.

## 10. Automation, Maintainability & Safe Change
*"What do I keep doing by hand that repeats? Would a new engineer understand this, and can we change it without fear?"*
- Automate the repetitive: deploys, migrations, checks, recurring ops.
- Single source of truth for anything duplicated; no config drift.
- Self-documenting code plus the docs, runbooks, and tooltips a newcomer needs.
- Stable, versioned API contracts; changes are backward-compatible or migrated in lockstep.
- Reversible, backward-compatible migrations; no-downtime deploys with a fast rollback path.

## 11. Legal, Compliance & Data Protection
*"If this leaked, got misused, or a user or regulator came asking, are we covered and compliant?"*
- Every user-facing surface has the legal pages it needs: Privacy Policy, Terms of Service, and a cookie/consent notice where applicable, linked and reachable.
- Disclose data processing: what personal data is collected, why, how long it is kept, and who it is shared with.
- Honor data-subject rights (access, export, correction, deletion) with a real mechanism, not just a promise.
- Know and meet the regulatory scope for the data handled (PII, payments, minors, health); get counsel review for anything binding.
- Capture and retain contracts and consents (signed terms, opt-ins, DPAs) for legal defensibility.
- Add disclaimers and limitation-of-liability wherever the tool gives advice, estimates, or financial figures.
- Engineering makes sure the pages and mechanisms EXIST and stay maintainable; a lawyer owns the actual wording. This is not legal advice.

---

**How to apply it:** while building, hold new code to every area as you write it. To review or audit, go area by area, ask the question, check the items, fix what fails, and add a regression test. Never take a shortcut that violates Section 6.
