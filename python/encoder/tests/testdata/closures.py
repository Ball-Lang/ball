# Nested def + read-only closure capture + a first-class function value called
# through a local.
def make_adder(base):
    def add(step):
        return base + step
    return add


add10 = make_adder(10)
print(add10(5))       # 15
print(add10(20))      # 30
