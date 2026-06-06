package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"strings"

	twin "github.com/condercx/twin-go"
)

var version = "dev"

func main() {
	listen := flag.String("listen", "", "listen address")
	password := flag.String("password", "", "auth password")
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
	if *listen == "" {
		*listen = ":80"
		fmt.Println("warning: no --listen specified, defaulting to :80")
	}

	startServer(*listen, *password)
}

func runWithConfig(path string) {
	f, err := os.Open(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open config: %v\n", err)
		os.Exit(1)
	}
	defer f.Close()

	var password string
	var listeners []twin.ListenerConfig

	scanner := bufio.NewScanner(f)
	var currentListener *twin.ListenerConfig
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if line == "[[listener]]" {
			if currentListener != nil {
				listeners = append(listeners, *currentListener)
			}
			currentListener = &twin.ListenerConfig{}
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		val := strings.TrimSpace(parts[1])
		switch key {
		case "password":
			password = val
		case "listen":
			if currentListener != nil {
				currentListener.Listen = val
			}
		case "tls":
			if currentListener != nil {
				currentListener.TLSMode = twin.TLSMode(val)
			}
		case "cert":
			if currentListener != nil {
				currentListener.CertFile = val
			}
		case "key":
			if currentListener != nil {
				currentListener.KeyFile = val
			}
		}
	}
	if currentListener != nil {
		listeners = append(listeners, *currentListener)
	}

	if err := scanner.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "read config: %v\n", err)
		os.Exit(1)
	}

	if password == "" {
		fmt.Println("error: password not set in config")
		os.Exit(1)
	}
	if len(listeners) == 0 {
		fmt.Println("error: no [[listener]] blocks found in config")
		os.Exit(1)
	}

	cfg := twin.ServerConfig{
		Password:  password,
		Listeners: listeners,
	}
	server, err := twin.NewServer(&cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create server: %v\n", err)
		os.Exit(1)
	}
	if err := server.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "start server: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("[twin] server started with %d listener(s)\n", len(listeners))
	<-server.Done()
}

func startServer(listen, password string) {
	cfg := twin.ServerConfig{
		Password: password,
		Listeners: []twin.ListenerConfig{
			{Listen: listen, TLSMode: twin.TLSModeWS},
		},
	}
	server, err := twin.NewServer(&cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create server: %v\n", err)
		os.Exit(1)
	}
	if err := server.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "start server: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("[twin] server listening on ws://%s\n", listen)
	<-server.Done()
}
