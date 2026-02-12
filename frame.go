package httpmux

import (
	"encoding/binary"
	"errors"
	"io"
)

const (
	FrameData  = 0x01
	FramePing  = 0x02
	FramePong  = 0x03
	FrameClose = 0x04
	FrameOpen  = 0x05 // payload: target string
)

type Frame struct {
	StreamID uint32
	Type     byte
	Length   uint32
	Payload  []byte
}

func WriteFrame(w io.Writer, fr *Frame) error {
	if fr == nil {
		return errors.New("nil frame")
	}
	h := make([]byte, 9)
	binary.BigEndian.PutUint32(h[0:4], fr.StreamID)
	h[4] = fr.Type
	binary.BigEndian.PutUint32(h[5:9], uint32(len(fr.Payload)))
	if _, err := w.Write(h); err != nil {
		return err
	}
	if len(fr.Payload) > 0 {
		_, err := w.Write(fr.Payload)
		return err
	}
	return nil
}

func ReadFrame(r io.Reader) (*Frame, error) {
	h := make([]byte, 9)
	if _, err := io.ReadFull(r, h); err != nil {
		return nil, err
	}
	sid := binary.BigEndian.Uint32(h[0:4])
	ft := h[4]
	l := binary.BigEndian.Uint32(h[5:9])

	var p []byte
	if l > 0 {
		p = make([]byte, l)
		if _, err := io.ReadFull(r, p); err != nil {
			return nil, err
		}
	}
	return &Frame{StreamID: sid, Type: ft, Length: l, Payload: p}, nil
}
