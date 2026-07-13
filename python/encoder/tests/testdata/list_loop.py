# list literal + for-over-list + indexing + an accumulator.
nums = [10, 20, 30]
total = 0
for n in nums:
    print(n)
    total = total + n
print(total)          # 60
print(nums[1])        # 20
