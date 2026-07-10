---
name: iterate
description: This skill should be used when the user asks to "iterate on Ball's <language> support", "audit the Dart/TS/C++/Rust Ball implementation", "fix a Ball conformance failure", "raise Ball test coverage", or invokes /ball:iterate <language>[, focus]. Covers auditing an existing Ball language target and driving bounded improvement lanes.
---

# Ball Iterate — audit and improve an existing Ball language target

Arguments: "$ARGUMENTS"

This is a **bootstrap wrapper**. The canonical, always-current contract lives inside the Ball repository and MUST be followed from there — never from memory of this or any older wrapper.

1. **Locate a Ball checkout.** If the current directory (or an ancestor) is a clone of `github.com/Ball-Lang/ball`, use it. Otherwise ask the user where to clone, then `git clone https://github.com/Ball-Lang/ball`.
2. **Work inside the checkout** on a branch, after running its permission-discovery step (the in-repo skill's §0).
3. **Read `.claude/skills/ball-iterate/SKILL.md` in the checkout** and follow it exactly as the binding contract, passing "$ARGUMENTS" through as its argument. It covers: permission discovery, the five-cell audit (conformance, coverage, fail-loud, completeness, docs), staleness verification against live CI, bounded delta-measured improvement lanes, and the honest close standard.
