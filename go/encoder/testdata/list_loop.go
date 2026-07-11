package main

import "fmt"

func main() {
	nums := []int{10, 20, 30}
	total := 0
	for _, n := range nums {
		fmt.Println(n)
		total += n
	}
	fmt.Println(total) // 60
}
