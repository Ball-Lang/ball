---
name: new
description: This skill should be used when the user asks to "add a new language to Ball", "bootstrap C#/Go/Python support for Ball", "create a Ball compiler/encoder/engine for <language>", or invokes /ball:new <language>. Covers the full target bootstrap - compiler, encoder, engine, CLI, conformance tests, and CI.
---

# Ball New — bootstrap a new Ball language target

Arguments: "$ARGUMENTS"

This is a **bootstrap wrapper**. The canonical, always-current contract lives inside the Ball repository and MUST be followed from there — never from memory of this or any older wrapper.

1. **Locate a Ball checkout.** If the current directory (or an ancestor) is a clone of `github.com/Ball-Lang/ball`, use it. Otherwise ask the user where to clone, then `git clone https://github.com/Ball-Lang/ball`.
2. **Work inside the checkout** on a branch, after running its permission-discovery step (the in-repo skill's §0).
3. **Read `.claude/skills/ball-new/SKILL.md` in the checkout** and follow it exactly as the binding contract, passing "$ARGUMENTS" through as its argument. It covers: permission discovery, recon, the epic + 10-phase issue tree (scaffold, proto bindings, runtime, compiler, encoder, engine, conformance, CLI, CI, docs), wave orchestration, and the corpus-parity close bar.

A language is only "done" when it can compile AND encode AND execute the Ball conformance corpus — a compiler without an encoder is a half-implementation.
