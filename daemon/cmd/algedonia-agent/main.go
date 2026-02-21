package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Println("algedonia-agent daemon starting...")

	// TODO: Parse CLI flags (server URL, token, etc.)
	// TODO: Establish persistent channel connection to Phoenix server
	// TODO: Enter main event loop

	_ = os.Args
}
