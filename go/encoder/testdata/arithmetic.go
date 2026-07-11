package main

import "fmt"

// add exercises the one-input convention: a multi-parameter Go function encodes
// to a single message-parameter Ball function, its arguments packed by name.
func add(a, b int) int {
	return a + b
}

func main() {
	x := add(2, 3)
	y := x * 4
	z := y - 2
	fmt.Println(z) // (2+3)*4 - 2 = 18
}
