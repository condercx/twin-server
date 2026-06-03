package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"

	twin "github.com/condercx/twin-go"
)

func main() {
	server := flag.String("server", "127.0.0.1:8443", "twin server address")
	password := flag.String("password", "", "auth password")
	insecure := flag.Bool("insecure", true, "skip TLS cert verification")
	sni := flag.String("sni", "", "TLS SNI override")
	target := flag.String("target", "https://www.google.com", "URL to fetch through twin")
	flag.Parse()

	if *password == "" {
		fmt.Println("error: --password is required")
		os.Exit(1)
	}

	host, portStr, err := net.SplitHostPort(*server)
	if err != nil {
		fmt.Fprintf(os.Stderr, "parse server addr: %v\n", err)
		os.Exit(1)
	}
	port, _ := strconv.Atoi(portStr)

	cfg := twin.DefaultConfig()
	cfg.ServerAddr = host
	cfg.ServerPort = port
	cfg.Password = *password
	cfg.SkipCert = *insecure
	cfg.SNI = *sni
	cfg.UpBPS = 100 * 1000 * 1000   // 100 Mbps
	cfg.DownBPS = 100 * 1000 * 1000 // 100 Mbps

	client := twin.NewClient(&cfg)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	fmt.Printf("connecting to twin server at %s:%d ...\n", host, port)

	udpAddr, err := net.ResolveUDPAddr("udp", *server)
	if err != nil {
		fmt.Fprintf(os.Stderr, "resolve: %v\n", err)
		os.Exit(1)
	}
	packetConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		fmt.Fprintf(os.Stderr, "udp conn: %v\n", err)
		os.Exit(1)
	}
	defer packetConn.Close()

	if err := client.Dial(ctx, packetConn, udpAddr); err != nil {
		fmt.Fprintf(os.Stderr, "dial failed: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()
	fmt.Println("connected!")

	fmt.Printf("fetching %s through twin ...\n", *target)
	httpClient := &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				stream, err := client.DialTCP(ctx, addr)
				if err != nil {
					return nil, err
				}
				return &streamConn{rc: stream}, nil
			},
		},
		Timeout: 15 * time.Second,
	}

	req, err := http.NewRequestWithContext(ctx, "GET", *target, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "http request: %v\n", err)
		os.Exit(1)
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "http get: %v\n", err)
		os.Exit(1)
	}
	defer resp.Body.Close()

	fmt.Printf("HTTP %s\n", resp.Status)
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	fmt.Printf("body (%d bytes):\n%s\n", len(body), string(body))
}

type streamConn struct {
	rc io.ReadWriteCloser
}

func (c *streamConn) Read(b []byte) (int, error)  { return c.rc.Read(b) }
func (c *streamConn) Write(b []byte) (int, error) { return c.rc.Write(b) }
func (c *streamConn) Close() error                { return c.rc.Close() }
func (c *streamConn) LocalAddr() net.Addr          { return nil }
func (c *streamConn) RemoteAddr() net.Addr         { return nil }
func (c *streamConn) SetDeadline(t time.Time) error      { return nil }
func (c *streamConn) SetReadDeadline(t time.Time) error  { return nil }
func (c *streamConn) SetWriteDeadline(t time.Time) error { return nil }
