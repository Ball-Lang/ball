# A descending range (negative step) — the step parses as UnaryOp(USub, ...),
# which the encoder unwraps to count downward with a `>` comparison.
for i in range(5, 0, -1):
    print(i)
