# Recursion: if + return + multiply/subtract, a single-parameter function.
def factorial(n):
    if n <= 1:
        return 1
    return n * factorial(n - 1)


print(factorial(5))   # 120
print(factorial(0))   # 1
