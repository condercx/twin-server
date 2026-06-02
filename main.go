package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"strconv"

	qtls "github.com/metacubex/tls"

	twin "github.com/condercx/twin-go"
)

var version = "dev"

func main() {
	listen := flag.String("listen", ":8443", "listen address")
	password := flag.String("password", "", "auth password")
	certFile := flag.String("cert", "", "TLS cert file")
	keyFile := flag.String("key", "", "TLS key file")
	confFile := flag.String("conf", "", "config file path")
	showVersion := flag.Bool("version", false, "show version")
	flag.Parse()

	if *showVersion {
		fmt.Println(version)
		os.Exit(0)
	}

	if *confFile != "" {
		runWithConfig(*confFile)
		return
	}

	if *password == "" {
		fmt.Println("error: --password is required")
		os.Exit(1)
	}
	if *certFile == "" || *keyFile == "" {
		fmt.Println("error: --cert and --key are required")
		os.Exit(1)
	}

	cert, err := qtls.LoadX509KeyPair(*certFile, *keyFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "load cert: %v\n", err)
		os.Exit(1)
	}

	host, portStr, err := net.SplitHostPort(*listen)
	if err != nil {
		fmt.Fprintf(os.Stderr, "parse listen addr: %v\n", err)
		os.Exit(1)
	}
	port, _ := strconv.Atoi(portStr)

	cfg := twin.Config{
		ServerAddr: host,
		ServerPort: port,
		Password:   *password,
	}
	cfg.TLSCert = cert

	server := twin.NewServer(&cfg)
	if err := server.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "start: %v\n", err)
		os.Exit(1)
	}

	<-make(chan struct{})
}

func runWithConfig(path string) {
	fmt.Printf("loading config from %s ...\n", path)
	fmt.Println("config file support coming soon")
	os.Exit(1)
}

