# Lessons Log

Repo-local mistake log. Complements the cross-session auto-memory system
(`C:\Users\Mike\.claude\projects\...\memory\`) — memory holds durable
facts/feedback about the user and project; this file holds concrete
in-repo mistakes and the rule that prevents each one from repeating.

Check this file at session start. After any correction from the user
(wrong approach, bad assumption, bug caused by missing context), append
an entry below in this format:

```
## YYYY-MM-DD — short title
**What happened:** concrete mistake, one line.
**Root cause:** why it happened.
**Rule:** what to do instead, going forward.
```

Keep entries terse. Delete/merge stale entries if the underlying code
changes enough that the rule no longer applies.

---
