# while + if/elif/else + modulo + printing both strings and ints.
def fizzbuzz(n):
    i = 1
    while i <= n:
        if i % 15 == 0:
            print("FizzBuzz")
        elif i % 3 == 0:
            print("Fizz")
        elif i % 5 == 0:
            print("Buzz")
        else:
            print(i)
        i += 1


fizzbuzz(15)
