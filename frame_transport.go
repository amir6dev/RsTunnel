package httpmux

// FrameTransport یک ترنسپورت فریم‌محور است (نه io.Reader/io.Writer)
type FrameTransport interface {
	Start() error
	Close() error
	Send(fr *Frame) error
	Recv() (*Frame, error) // بلاک می‌کند تا فریمی برسد یا خطا بدهد
}
