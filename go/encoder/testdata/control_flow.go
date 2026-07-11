package main

import "fmt"

func main() {
	sum := 0
	for i := 1; i <= 5; i++ {
		if i%2 == 0 {
			sum += i
		} else {
			sum += 0
		}
	}
	fmt.Println(sum) // 2 + 4 = 6
}
