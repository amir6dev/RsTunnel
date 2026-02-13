package httpmux

// FrameTransport is the common interface implemented by transports that carry framed
// messages between client and server.
type FrameTransport interface {
	Start() error
	Close() error
	Send(*Frame) error
	Recv() (*Frame, error)
}
