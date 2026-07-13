# String concatenation + f-strings + len(), the common string surface.
def greet(name):
    return "Hello, " + name + "!"


msg = greet("Ball")
print(msg)                          # Hello, Ball!
print(len(msg))                     # 12
print(f"{msg} has {len(msg)} chars")
