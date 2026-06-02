package main

import (
	"bufio"
	"flag"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"

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

	startServer(*listen, *password, *certFile, *keyFile)
}

func runWithConfig(path string) {
	f, err := os.Open(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open config: %v\n", err)
		os.Exit(1)
	}
	defer f.Close()

	var listen, password, certFile, keyFile string

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		val := strings.TrimSpace(parts[1])
		switch key {
		case "listen":
			listen = val
		case "password":
			password = val
		case "cert":
			certFile = val
		case "key":
			keyFile = val
		}
	}

	if err := scanner.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "read config: %v\n", err)
		os.Exit(1)
	}

	if listen == "" {
		listen = ":8443"
	}
	if password == "" {
		fmt.Println("error: password not set in config")
		os.Exit(1)
	}
	if certFile == "" || keyFile == "" {
		fmt.Println("error: cert and key must be set in config")
		os.Exit(1)
	}

	startServer(listen, password, certFile, keyFile)
}

func startServer(listen, password, certFile, keyFile string) {
	cert, err := qtls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "load cert: %v\n", err)
		os.Exit(1)
	}

	host, portStr, err := net.SplitHostPort(listen)
	if err != nil {
		fmt.Fprintf(os.Stderr, "parse listen addr: %v\n", err)
		os.Exit(1)
	}
	port, _ := strconv.Atoi(portStr)

	cfg := twin.Config{
		ServerAddr: host,
		ServerPort: port,
		Password:   password,
	}
	cfg.TLSCert = cert

	fmt.Printf("[twin] twin server listening on %s\n", listen)
	server := twin.NewServer(&cfg)
	if err := server.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "start: %v\n", err)
		os.Exit(1)
	}

	<-make(chan struct{})
}

