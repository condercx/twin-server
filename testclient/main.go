package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	twin "github.com/condercx/twin-go"
)

func main() {
	server := flag.String("server", "127.0.0.1:80", "server address")
	password := flag.String("password", "", "auth password")
	target := flag.String("target", "https://www.baidu.com", "test target")
	tlsMode := flag.String("tls", "ws", "tls mode: ws or wss")
	sni := flag.String("sni", "", "TLS SNI (wss only)")
	insecure := flag.Bool("insecure", false, "skip cert verify (wss only)")
	ipsStr := flag.String("ips", "", "comma-separated IPs for NetDial")
	flag.Parse()

	if *password == "" {
		fmt.Println("error: --password is required")
		os.Exit(1)
	}

	addr := *server
	port := 80
	if h, p, err := net.SplitHostPort(addr); err == nil {
		addr = h
		if p != "" {
			if parsed, e := strconv.Atoi(p); e == nil {
				port = parsed
			}
		}
	}
	tlsModeStr := *tlsMode
	if tlsModeStr == "" {
		tlsModeStr = "ws"
	}

	var proxyIPs []string
	if *ipsStr != "" {
		for _, ip := range strings.Split(*ipsStr, ",") {
			ip = strings.TrimSpace(ip)
			if ip != "" {
				proxyIPs = append(proxyIPs, ip)
			}
		}
	}

	cfg := twin.ClientConfig{
		ServerAddr:   addr,
		ServerPort:   port,
		Password:     *password,
		TLSMode:      twin.TLSMode(tlsModeStr),
		SNI:          *sni,
		Insecure:     *insecure,
		ConnCount:    2,
		ProxyIPs:     proxyIPs,
	}

	client, err := twin.NewClient(&cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create client: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	fmt.Printf("[testclient] connected to ws://%s\n", *server)

	fmt.Printf("[testclient] testing TCP: %s\n", *target)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, err := client.DialTCP(ctx, *target)
	if err != nil {
		fmt.Fprintf(os.Stderr, "TCP dial failed: %v\n", err)
		os.Exit(1)
	}

	req := fmt.Sprintf("GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", *target)
	if _, err := conn.Write([]byte(req)); err != nil {
		fmt.Fprintf(os.Stderr, "TCP write failed: %v\n", err)
		os.Exit(1)
	}

	resp, _ := io.ReadAll(conn)
	fmt.Printf("[testclient] TCP response: %d bytes\n", len(resp))
	conn.Close()

	fmt.Println("[testclient] testing UDP: DNS")
	pc, err := client.ListenPacket()
	if err != nil {
		fmt.Fprintf(os.Stderr, "ListenPacket failed: %v\n", err)
		os.Exit(1)
	}
	defer pc.Close()

	dnsQuery := []byte{0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x77, 0x77, 0x77, 0x06, 0x67, 0x6f, 0x6f, 0x67, 0x6c, 0x65, 0x03, 0x63, 0x6f, 0x6d, 0x00, 0x00, 0x01, 0x00, 0x01}
	dnsAddr, _ := net.ResolveUDPAddr("udp", "8.8.8.8:53")
	pc.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if _, err := pc.WriteTo(dnsQuery, dnsAddr); err != nil {
		fmt.Fprintf(os.Stderr, "UDP write failed: %v\n", err)
		os.Exit(1)
	}

	buf := make([]byte, 512)
	pc.SetReadDeadline(time.Now().Add(5 * time.Second))
	n, _, err := pc.ReadFrom(buf)
	if err != nil {
		fmt.Fprintf(os.Stderr, "UDP read failed: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("[testclient] UDP response: %d bytes\n", n)

	fmt.Println("[testclient] all tests passed!")
}
