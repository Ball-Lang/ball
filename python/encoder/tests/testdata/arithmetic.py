# Exercises the one-input convention: a multi-parameter function encodes to a
# single message-parameter Ball function, its arguments packed by name.
def add(a, b):
    return a + b


x = add(2, 3)
y = x * 4
z = y - 2
print(z)  # (2 + 3) * 4 - 2 = 18
