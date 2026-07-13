# for-over-range + if/else + break/continue + an accumulator, proving the
# hoisted-locals strategy (sum is mutated across nested block scopes).
total = 0
for i in range(1, 11):
    if i == 8:
        break
    if i % 2 != 0:
        continue
    total = total + i
print(total)  # 2 + 4 + 6 = 12
