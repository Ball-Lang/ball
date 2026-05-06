183 works by calling `runtimeType` on built-in values only; custom message objects do not expose that virtual property in the Dart engine.

184 can stay simple with nested `if` chains plus `index`/`length` checks; it still exercises nested matching behavior without relying on extra pattern syntax.
