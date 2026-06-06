module github.com/condercx/twin-server

go 1.22

require github.com/condercx/twin-go v0.0.0

require (
	github.com/google/uuid v1.6.0 // indirect
	github.com/gorilla/websocket v1.5.3 // indirect
	github.com/xtaci/smux v1.5.24 // indirect
)

replace github.com/condercx/twin-go => ../FlClash/core/twin
